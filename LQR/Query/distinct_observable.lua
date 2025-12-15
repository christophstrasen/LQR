-- Schema-aware distinct operator with windowed retention (count or time).
local rx = require("reactivex")
local Expiration = require("LQR/JoinObservable/expiration")
local Result = require("LQR/JoinObservable/result")
local Schema = require("LQR/JoinObservable/schema")
local Log = require("LQR/util/log").withTag("distinct")

local function default_now()
	if os and type(os.time) == "function" then
		return os.time
	end
	return function()
		return 0
	end
end

local DEFAULT_WINDOW_COUNT = 1000

local DistinctObservable = {}

local function warnUnknownKeys(tbl, allowed, label)
	if type(tbl) ~= "table" then
		return
	end
	for key in pairs(tbl) do
		if not allowed[key] then
			Log:warn("%s ignored unknown key '%s'", label, tostring(key))
		end
	end
end

local VALID_DISTINCT_WINDOW_KEYS = {
	count = true,
	maxItems = true,
	mode = true,
	time = true,
	offset = true,
	field = true,
	currentFn = true,
	gcOnInsert = true,
	gcBatchSize = true,
	gcIntervalSeconds = true,
	gcScheduleFn = true,
}

local function valueFromPath(entry, path)
	if type(path) ~= "string" or path == "" then
		return nil
	end
	local cursor = entry
	for token in string.gmatch(path, "([^.]+)") do
		if type(cursor) ~= "table" then
			return nil
		end
		cursor = cursor[token]
	end
	return cursor
end

local function normalizeKeySelector(by)
	if type(by) == "function" then
		return by
	end
	if type(by) == "string" then
		return function(entry)
			return valueFromPath(entry, by)
		end
	end
	error("distinct expects by to be a field name (string) or function")
end

local function normalizeWindow(window, scheduler)
	window = window or {}
	local alreadyValidated = window.__validated == true
	if not alreadyValidated then
		warnUnknownKeys(window, VALID_DISTINCT_WINDOW_KEYS, "distinct.window")
			if window.mode and window.mode ~= "count" and window.mode ~= "time" and window.mode ~= "interval" then
				Log:warn("distinct.window - unsupported mode '%s'; defaulting to count/time auto-detection", tostring(window.mode))
				window.mode = nil
			end
			local count = window.count or window.maxItems
			if count ~= nil and (type(count) ~= "number" or count <= 0) then
				Log:warn("distinct.window - count/maxItems should be a positive number; defaulting to %d", DEFAULT_WINDOW_COUNT)
				window.count = DEFAULT_WINDOW_COUNT
				window.maxItems = nil
			end
			local wantsTime = window.mode == "time" or window.mode == "interval" or window.time ~= nil or window.offset ~= nil
			if wantsTime then
				if window.field ~= nil and type(window.field) ~= "string" then
					Log:warn("distinct.window - field should be a string; defaulting to 'sourceTime'")
					window.field = "sourceTime"
				end
				local offset = window.time or window.offset
				if offset ~= nil and (type(offset) ~= "number" or offset < 0) then
					Log:warn("distinct.window - time/offset should be a non-negative number; defaulting to 0")
					window.time = 0
					window.offset = nil
				end
				if window.currentFn ~= nil and type(window.currentFn) ~= "function" then
					Log:warn("distinct.window - currentFn should be a function; ignoring provided value")
					window.currentFn = nil
				end
				if window.gcBatchSize ~= nil and (type(window.gcBatchSize) ~= "number" or window.gcBatchSize < 1) then
					Log:warn("distinct.window - gcBatchSize should be a positive integer; defaulting to 1")
					window.gcBatchSize = 1
				end
			end
		window.__validated = true
	end

	local normalized = {
		gcOnInsert = window.gcOnInsert,
		gcBatchSize = window.gcBatchSize,
		gcIntervalSeconds = window.gcIntervalSeconds,
		gcScheduleFn = window.gcScheduleFn,
	}

	local wantsInterval = window.mode == "time" or window.mode == "interval" or window.time or window.offset
	if window.count or window.maxItems or window.mode == "count" or not wantsInterval then
		normalized.joinWindow = {
			mode = "count",
			maxItems = window.count or window.maxItems or DEFAULT_WINDOW_COUNT,
		}
	else
		normalized.joinWindow = {
			mode = "interval",
			field = window.field or "sourceTime",
			offset = window.time or window.offset or 0,
			currentFn = window.currentFn or default_now(),
		}
	end

	local scheduleFn = normalized.gcScheduleFn
	if not scheduleFn and scheduler and scheduler.schedule then
		scheduleFn = function(delaySeconds, fn)
			return scheduler:schedule(fn, delaySeconds)
		end
	end
	if not scheduleFn and rx.scheduler and rx.scheduler.schedule then
		scheduleFn = function(delaySeconds, fn)
			return rx.scheduler.schedule(fn, delaySeconds or 0)
		end
	end
	if not scheduleFn then
		local sched = rx.scheduler and rx.scheduler.get and rx.scheduler.get()
		if sched and sched.schedule then
			if tostring(sched) == "TimeoutScheduler" then
				scheduleFn = function(delaySeconds, fn)
					return sched:schedule(fn, (delaySeconds or 0) * 1000)
				end
			else
				scheduleFn = function(delaySeconds, fn)
					return sched:schedule(fn, delaySeconds or 0)
				end
			end
		end
	end
	if scheduleFn then
		normalized.gcScheduleFn = scheduleFn
	end

	if normalized.gcOnInsert == nil then
		normalized.gcOnInsert = true
	end
	if normalized.gcBatchSize == nil then
		normalized.gcBatchSize = 1
	end

	return normalized
end

local function isJoinResult(value)
	return getmetatable(value) == Result
end

---@param source rx.Observable
---@param opts table
---@return rx.Observable, rx.Observable
function DistinctObservable.createDistinctObservable(source, opts)
	assert(type(opts) == "table", "distinct expects opts table")
	assert(opts.schema and opts.schema ~= "", "distinct requires a schema name")
	local schemaName = opts.schema
	local keySelector = normalizeKeySelector(opts.by or opts.field)
	local windowConfig = normalizeWindow(opts.window, opts.scheduler)
	local expiredSubject = rx.Subject.create()
	local expiredClosed = false

	local expirationConfig = Expiration.normalize({
		joinWindow = windowConfig.joinWindow,
	})

	local publishExpiration = function(key, record, reason)
		if not record or expiredClosed then
			return
		end
		local entry = record.entry
		local meta = entry and entry.RxMeta
		local id = (meta and meta.id) or (entry and entry.id)
		local sourceTime = (meta and meta.sourceTime) or (entry and entry[windowConfig.joinWindow.field or "sourceTime"])
		expiredSubject:onNext({
			schema = schemaName,
			key = key,
			reason = reason,
			entry = entry,
			id = id,
			sourceTime = sourceTime,
			origin = "distinct",
		})
	end

	local enforceRetention = Expiration.createEnforcer(expirationConfig.left, function(_, key, record, reason)
		publishExpiration(key, record, reason)
	end, function() end)

	local function closeExpired(method, ...)
		if expiredClosed then
			return
		end
		expiredClosed = true
		expiredSubject[method](expiredSubject, ...)
	end

	local function flushCache(cache, order, reason)
		for key, buffer in pairs(cache) do
			if buffer and buffer.entries then
				for _, record in ipairs(buffer.entries) do
					publishExpiration(key, record, reason)
				end
			end
			cache[key] = nil
		end
		if order then
			-- Avoid relying on Lua's `#` for tables with holes.
			for index in pairs(order) do
				order[index] = nil
			end
		end
	end

	local function startPeriodicGc(runGc)
		local interval = windowConfig.gcIntervalSeconds
		if not interval or interval <= 0 then
			return nil
		end
		local scheduleFn = windowConfig.gcScheduleFn
		if not scheduleFn then
			Log:warn("[distinct] gcIntervalSeconds configured but no scheduler available; GC disabled")
			return nil
		end

		local subscription
		local function tick()
			runGc("periodic")
			if not scheduleFn then
				return
			end
			subscription = scheduleFn(interval, tick)
		end
		subscription = scheduleFn(interval, tick)

		return function()
			if not subscription then
				return
			end
			if type(subscription) == "function" then
				subscription()
			elseif subscription.unsubscribe then
				subscription:unsubscribe()
			elseif subscription.dispose then
				subscription:dispose()
			end
		end
	end

		local observable = rx.Observable.create(function(observer)
			local cache, order = {}, {}
			local orderHead = 1
			local orderTail = 0
			local batchCounter = 0
			local warnedClockBehind = false
			local debugEvents = 0
			local maxDebugEvents = 25

			local function compactOrderIfNeeded()
				-- Avoid unbounded growth when we keep popping from the head.
				-- This compacts occasionally and keeps amortized cost low.
				if orderHead <= 128 then
					return
				end
				if orderHead <= (orderTail / 2) then
					return
				end
				local newOrder = {}
				for i = orderHead, orderTail do
					local entry = order[i]
					if entry then
						newOrder[#newOrder + 1] = entry
					end
				end
				order = newOrder
				orderHead = 1
				orderTail = #order
			end

			local function enforceIntervalRetention(reason)
				local joinWindow = windowConfig.joinWindow
				local currentFn = joinWindow.currentFn
			local field = joinWindow.field
			local offset = joinWindow.offset or 0

			local now = currentFn()
				if type(now) ~= "number" then
					Log:warn("[distinct] currentFn returned non-number; skipping interval GC")
					return
				end

				-- NOTE: We intentionally avoid relying on Lua's `#` length operator here because `order` is
				-- a queue where we nil out head indices. Some runtimes (e.g. PZ Kahlua) compute `#` by
				-- scanning from index 1 and would return 0 once order[1] is nil, stalling retention forever.
				while orderHead <= orderTail do
					local headEntry = order[orderHead]
					if not headEntry then
						orderHead = orderHead + 1
					else
					local key = headEntry.key
					local record = headEntry.record
					local buffer = key and cache[key]
					local stored = buffer and buffer.entries and buffer.entries[1] or nil
					if stored ~= record then
						-- Stale order entry (already evicted/cleared).
						order[orderHead] = nil
						orderHead = orderHead + 1
					else
						local entry = record and record.entry
						local meta = entry and entry.RxMeta
						local value = meta and meta.sourceTime or (entry and entry[field])

						if type(value) ~= "number" then
							-- NOTE: Unlike JoinObservable interval GC (which only warns), distinct would stall forever
							-- if the head entry can't be evaluated. For bounded memory and forward progress we evict it.
							Log:warn(
								"[distinct] Cannot evaluate interval expiration for %s entry - field '%s' missing or not numeric; evicting",
								tostring(schemaName),
								tostring(field)
							)
							cache[key] = nil
							order[orderHead] = nil
							orderHead = orderHead + 1
							publishExpiration(key, record, expirationConfig.left.reason or "expired_interval")
						elseif (now - value) > offset then
							cache[key] = nil
							order[orderHead] = nil
							orderHead = orderHead + 1
							publishExpiration(key, record, expirationConfig.left.reason or "expired_interval")
						elseif now < value then
							-- Guard: if the configured clock is behind the entry timestamp, the distinct cache would stall
							-- (nothing ever expires because the head entry is "in the future"). Evict to keep forward progress.
							if not warnedClockBehind then
								warnedClockBehind = true
								Log:warn(
									"[distinct] currentFn is behind entry sourceTime for schema=%s (now=%s, sourceTime=%s); evicting to avoid stall",
									tostring(schemaName),
									tostring(now),
									tostring(value)
								)
							end
							cache[key] = nil
							order[orderHead] = nil
							orderHead = orderHead + 1
							publishExpiration(key, record, "expired_clock_skew")
						else
							break
						end
					end
				end
			end

				compactOrderIfNeeded()
			end

			local function runGc(reason)
				if windowConfig.joinWindow.mode == "interval" then
					enforceIntervalRetention(reason)
				else
					enforceRetention(cache, order, "distinct")
				end
				if reason == "completed" or reason == "disposed" then
					flushCache(cache, order, reason)
					orderHead = 1
					orderTail = 0
				end
			end

		local cancelGc = startPeriodicGc(runGc)

		local function handleRecord(record, emitValue)
			local ok, key = pcall(keySelector, record)
			if not ok then
				Log:warn("[distinct] dropping %s entry; key selector errored - %s", tostring(schemaName), tostring(key))
				return
			end
			if key == nil then
				Log:warn("[distinct] dropping %s entry because key resolved to nil", tostring(schemaName))
				return
			end

			local meta = type(record) == "table" and record.RxMeta or nil
			local sourceTime = meta and meta.sourceTime or nil
			local joinWindow = windowConfig.joinWindow
			local now = nil
			if joinWindow and joinWindow.mode == "interval" and type(joinWindow.currentFn) == "function" then
				now = joinWindow.currentFn()
			end
			if debugEvents < maxDebugEvents then
				debugEvents = debugEvents + 1
				Log:debug(
					"[distinct] in schema=%s key=%s now=%s sourceTime=%s offset=%s",
					tostring(schemaName),
					tostring(key),
					tostring(now),
					tostring(sourceTime),
					tostring(joinWindow and joinWindow.offset)
				)
			end

			if windowConfig.gcOnInsert then
				-- Optional batching for interval GC to reduce overhead under high ingest rates.
				-- Default is 1 (run on every insert), preserving current behavior.
				if windowConfig.joinWindow.mode == "interval" and (windowConfig.gcBatchSize or 1) > 1 then
					batchCounter = batchCounter + 1
					if (batchCounter % (windowConfig.gcBatchSize or 1)) == 0 then
						runGc("insert")
					end
				else
					runGc("insert")
				end
			end

			local buffer = cache[key]
			if buffer and buffer.entries and #buffer.entries > 0 then
				-- Suppress duplicate; keep original entry so retention is based on first arrival.
				if debugEvents < maxDebugEvents then
					debugEvents = debugEvents + 1
					Log:debug("[distinct] suppress schema=%s key=%s", tostring(schemaName), tostring(key))
				end
				publishExpiration(key, { entry = record, schemaName = schemaName }, "distinct_schema")
				return
			end

			local stored = {
				entry = record,
				key = key,
				schemaName = schemaName,
			}
				cache[key] = { entries = { stored } }
				orderTail = orderTail + 1
				order[orderTail] = { key = key, record = stored }
				observer:onNext(emitValue or stored.entry)
			end

		local function handleEntry(entry)
			if isJoinResult(entry) then
				local record = entry:get(schemaName)
				if not record then
					observer:onNext(entry)
					return
				end
				handleRecord(record, entry)
				return
			end

			local ok, meta = pcall(Schema.assertRecordHasMeta, entry, "distinct")
			if not ok or not meta then
				Log:warn("[distinct] dropping entry that is missing schema metadata")
				return
			end
			if meta.schema ~= schemaName then
				observer:onNext(entry)
				return
			end
			handleRecord(entry)
		end

		local subscription
		subscription = source:subscribe(function(entry)
			handleEntry(entry)
		end, function(err)
			if cancelGc then
				cancelGc()
			end
			observer:onError(err)
			closeExpired("onError", err)
		end, function()
			runGc("completed")
			if cancelGc then
				cancelGc()
			end
			observer:onCompleted()
			closeExpired("onCompleted")
		end)

		return function()
			if subscription then
				subscription:unsubscribe()
			end
			runGc("disposed")
			if cancelGc then
				cancelGc()
			end
			closeExpired("onCompleted")
		end
	end)

	return observable, expiredSubject
end

return DistinctObservable
