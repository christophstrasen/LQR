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
			Log:warn("distinct.window: unsupported mode '%s'; defaulting to count/time auto-detection", tostring(window.mode))
			window.mode = nil
		end
		local count = window.count or window.maxItems
		if count ~= nil and (type(count) ~= "number" or count <= 0) then
			Log:warn("distinct.window: count/maxItems should be a positive number; defaulting to %d", DEFAULT_WINDOW_COUNT)
			window.count = DEFAULT_WINDOW_COUNT
			window.maxItems = nil
		end
		local wantsTime = window.mode == "time" or window.mode == "interval" or window.time ~= nil or window.offset ~= nil
		if wantsTime then
			if window.field ~= nil and type(window.field) ~= "string" then
				Log:warn("distinct.window: field should be a string; defaulting to 'sourceTime'")
				window.field = "sourceTime"
			end
			local offset = window.time or window.offset
			if offset ~= nil and (type(offset) ~= "number" or offset < 0) then
				Log:warn("distinct.window: time/offset should be a non-negative number; defaulting to 0")
				window.time = 0
				window.offset = nil
			end
			if window.currentFn ~= nil and type(window.currentFn) ~= "function" then
				Log:warn("distinct.window: currentFn should be a function; ignoring provided value")
				window.currentFn = nil
			end
		end
		window.__validated = true
	end

	local normalized = {
		gcOnInsert = window.gcOnInsert,
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
			for i = #order, 1, -1 do
				order[i] = nil
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

		local function runGc(reason)
			enforceRetention(cache, order, "distinct")
			if reason == "completed" or reason == "disposed" then
				flushCache(cache, order, reason)
			end
		end

		local cancelGc = startPeriodicGc(runGc)

		local function handleRecord(record, emitValue)
			local ok, key = pcall(keySelector, record)
			if not ok then
				Log:warn("[distinct] dropping %s entry; key selector errored: %s", tostring(schemaName), tostring(key))
				return
			end
			if key == nil then
				Log:warn("[distinct] dropping %s entry because key resolved to nil", tostring(schemaName))
				return
			end

			if windowConfig.gcOnInsert then
				runGc("insert")
			end

			local buffer = cache[key]
			if buffer and buffer.entries and #buffer.entries > 0 then
				-- Suppress duplicate; keep original entry so retention is based on first arrival.
				publishExpiration(key, { entry = record, schemaName = schemaName }, "distinct_schema")
				return
			end

			local stored = {
				entry = record,
				key = key,
				schemaName = schemaName,
			}
			cache[key] = { entries = { stored } }
			order[#order + 1] = { key = key, record = stored }
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
