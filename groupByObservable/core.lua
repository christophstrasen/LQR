local rx = require("reactivex")
local Log = require("util.log").withTag("group")
local DataModel = require("groupByObservable.data_model")

local GroupByCore = {}

local function splitPath(path)
	local segments = {}
	for segment in string.gmatch(path or "", "[^%.]+") do
		segments[#segments + 1] = segment
	end
	return segments
end

local function getNested(root, path)
	local current = root
	for _, segment in ipairs(splitPath(path)) do
		if type(current) ~= "table" then
			return nil
		end
		current = current[segment]
	end
	return current
end

local function isPrimitive(value)
	local t = type(value)
	return t == "string" or t == "number" or t == "boolean"
end

-- Explainer: normalizeWindow mirrors joinWindow semantics so GC options behave consistently.
-- We intentionally keep gcOnInsert defaulting to true and support periodic GC via gcIntervalSeconds/gcScheduleFn.
local function normalizeWindow(opts)
	opts = opts or {}
	if opts.count and opts.count > 0 then
		return {
			mode = "count",
			count = opts.count,
			gcOnInsert = opts.gcOnInsert ~= false,
			gcIntervalSeconds = opts.gcIntervalSeconds,
			gcScheduleFn = opts.gcScheduleFn,
		}
	end
	return {
		mode = "time",
		time = opts.time or 0,
		field = opts.field or "sourceTime",
		currentFn = opts.currentFn or os.time,
		gcOnInsert = opts.gcOnInsert ~= false,
		gcIntervalSeconds = opts.gcIntervalSeconds,
		gcScheduleFn = opts.gcScheduleFn,
	}
end

-- Explainer: enforceWindow trims a single group's entries according to the configured window.
-- For count windows we drop oldest entries; for time windows we drop entries older than (now - time).
-- We return evicted entries so the caller can emit expirations for observability/debugging.
local function enforceWindow(entries, window, now)
	if window.mode == "count" then
		local evicted = {}
		while #entries > window.count do
			local removed = table.remove(entries, 1)
			evicted[#evicted + 1] = removed
		end
		return evicted
	end

	local evicted = {}
	local threshold = now - window.time
	while #entries > 0 do
		local entry = entries[1]
		-- We intentionally require a timestamp to evict; if time is missing we keep the entry rather than guessing.
		if entry.time ~= nil and entry.time < threshold then
			table.remove(entries, 1)
			evicted[#evicted + 1] = entry
		else
			break
		end
	end
	return evicted
end

-- Explainer: computeAggregates folds the current window entries into flat path→value maps per aggregate kind.
-- We keep per-kind tables keyed by dotted path so the data_model can project into _sum/_avg/_min/_max later.
-- avg returns nil when no numeric samples are present, matching the spec.
local function computeAggregates(entries, aggregateConfig)
	local aggregates = {
		count = #entries,
		sum = {},
		avg = {},
		min = {},
		max = {},
	}

	local function accumulate(kind, paths)
		if type(paths) ~= "table" then
			return
		end
		for _, path in ipairs(paths) do
			if type(path) == "string" and path ~= "" then
				local total = 0
				local seen = 0
				local minVal
				local maxVal
				for _, entry in ipairs(entries) do
					local v = getNested(entry.value, path)
					if type(v) == "number" then
						total = total + v
						seen = seen + 1
						if minVal == nil or v < minVal then
							minVal = v
						end
						if maxVal == nil or v > maxVal then
							maxVal = v
						end
					end
				end
				if kind == "sum" and seen > 0 then
					aggregates.sum[path] = total
				elseif kind == "min" and seen > 0 then
					aggregates.min[path] = minVal
				elseif kind == "max" and seen > 0 then
					aggregates.max[path] = maxVal
				elseif kind == "avg" then
					if seen > 0 then
						aggregates.avg[path] = total / seen
					else
						aggregates.avg[path] = nil
					end
				end
			end
		end
	end

	accumulate("sum", aggregateConfig.sum)
	accumulate("avg", aggregateConfig.avg)
	accumulate("min", aggregateConfig.min)
	accumulate("max", aggregateConfig.max)

	return aggregates
end

---Creates aggregate and enriched streams for grouped rows.
---@param source rx.Observable
---@param options table
---@field options.keySelector fun(row:table):string|number|boolean
---@field options.groupName string|nil
---@field options.window table
---@field options.aggregates table
---@field options.viewLabel string|nil
---@return rx.Observable aggregateStream
---@return rx.Observable enrichedStream
---@return rx.Observable expiredStream
---Creates aggregate and enriched streams for grouped rows.
-- Explainer: we subscribe once to the source, maintain per-key windows, and emit both aggregate rows
-- (schema-tagged for downstream joins) and enriched events (inline aggregates) on every insert.
-- Optional periodic GC mirrors join behavior so time windows still expire during idle periods.
function GroupByCore.createGroupByObservable(source, options)
	assert(source and source.subscribe, "createGroupByObservable expects an observable source")
	options = options or {}
	local keySelector = options.keySelector
	assert(type(keySelector) == "function", "options.keySelector must be a function")
	local window = normalizeWindow(options.window)
	local aggregatesConfig = options.aggregates or {}
	local groupNameOverride = options.groupName
	local flushOnComplete = options.flushOnComplete ~= false
	local viewLabel = options.viewLabel or "aggregate"

	local aggregateSubject = rx.Subject.create()
	local enrichedSubject = rx.Subject.create()
	local expiredSubject = rx.Subject.create()

	local state = {}

	local function emitForKey(key, entryList, currentRow)
		-- Recompute aggregates per insert so downstream sees up-to-date group state.
		local aggregates = computeAggregates(entryList, aggregatesConfig)
		aggregates.count = #entryList

		local windowMeta = nil
		if window.mode == "time" then
			local earliest = entryList[1] and entryList[1].time or nil
			local latest = entryList[#entryList] and entryList[#entryList].time or nil
			if earliest and latest then
				windowMeta = { start = earliest, ["end"] = latest }
			end
		end

		-- Aggregate view: schema-tagged rows that can flow into further joins.
		local aggregateRow = DataModel.buildAggregateRow({
			groupName = groupNameOverride or (key ~= nil and tostring(key)) or nil,
			key = key,
			aggregates = aggregates,
			window = windowMeta,
		})
		aggregateSubject:onNext(aggregateRow)

		-- Enriched view: original row plus inline aggregates/prefixes.
		local enriched = DataModel.buildEnrichedRow(currentRow, {
			groupName = groupNameOverride or (key ~= nil and tostring(key)) or nil,
			key = key,
			aggregates = aggregates,
		})
		enrichedSubject:onNext(enriched)
		-- Lower-level observability; keep at debug to avoid spamming app logs.
		Log:debug("[group] key=%s view=%s count=%s", tostring(key), tostring(viewLabel), tostring(aggregates.count))
	end

	local subscription
	local gcSubscription

	local function tickPeriodicGC()
		if window.mode ~= "time" or not window.gcIntervalSeconds or window.gcIntervalSeconds <= 0 then
			return
		end
		local scheduleFn = window.gcScheduleFn
		if not scheduleFn then
			local scheduler = rx.scheduler and rx.scheduler.get and rx.scheduler.get()
			if scheduler and tostring(scheduler) == "TimeoutScheduler" and scheduler.schedule then
				-- Support TimeoutScheduler (ms-based) when available, like Join.
				scheduleFn = function(delaySeconds, fn)
					return scheduler:schedule(fn, (delaySeconds or 0) * 1000)
				end
			elseif scheduler and scheduler.schedule then
				scheduleFn = function(delaySeconds, fn)
					return scheduler:schedule(fn, delaySeconds or 0)
				end
			end
		end
		if not scheduleFn then
			return
		end
		local function sweepAll()
			local now = window.currentFn()
			for key, bucket in pairs(state) do
				local evicted = enforceWindow(bucket.entries, window, now)
				if evicted and #evicted > 0 then
					for _, ev in ipairs(evicted) do
						expiredSubject:onNext({
							key = key,
							reason = "expired",
							value = ev.value,
							time = ev.time,
						})
					end
					Log:debug("[group] periodic GC evicted=%s key=%s", tostring(#evicted), tostring(key))
				end
			end
			gcSubscription = scheduleFn(window.gcIntervalSeconds, sweepAll)
		end
		gcSubscription = scheduleFn(window.gcIntervalSeconds, sweepAll)
	end

	subscription = source:subscribe(function(row)
		local ok, keyOrErr = pcall(keySelector, row)
		if not ok then
			Log:warn("groupBy keySelector errored: %s", tostring(keyOrErr))
			return
		end
		local key = keyOrErr
		if not isPrimitive(key) then
			Log:warn("groupBy key must be primitive, got %s", tostring(key))
			return
		end

		local entryTime
		if window.mode == "time" then
			entryTime = getNested(row, window.field)
			if entryTime == nil and type(row) == "table" and type(row.RxMeta) == "table" then
				entryTime = row.RxMeta[window.field]
			end
			entryTime = entryTime or window.currentFn()
		end

		local bucket = state[key]
		if not bucket then
			bucket = { entries = {} }
			state[key] = bucket
		end

		bucket.entries[#bucket.entries + 1] = {
			value = row,
			time = entryTime,
		}

		local now = window.mode == "time" and window.currentFn() or nil
		if window.gcOnInsert ~= false then
			local evicted = enforceWindow(bucket.entries, window, now)
			if evicted and #evicted > 0 then
				for _, ev in ipairs(evicted) do
					expiredSubject:onNext({
						key = key,
						reason = window.mode == "time" and "expired" or "evicted",
						value = ev.value,
						time = ev.time,
					})
				end
				Log:debug("[group] evicted=%s key=%s reason=%s", tostring(#evicted), tostring(key),
					window.mode == "time" and "expired" or "evicted")
			end
		end

		emitForKey(key, bucket.entries, row)
	end, function(err)
		aggregateSubject:onError(err)
		enrichedSubject:onError(err)
		expiredSubject:onError(err)
	end, function()
			if flushOnComplete then
				for key, bucket in pairs(state) do
					for _, ev in ipairs(bucket.entries) do
						expiredSubject:onNext({
							key = key,
							reason = "completed",
							value = ev.value,
							time = ev.time,
						})
					end
				end
			end
		aggregateSubject:onCompleted()
		enrichedSubject:onCompleted()
		expiredSubject:onCompleted()
	end)

	tickPeriodicGC()

	local function teardown()
		if subscription then
			subscription:unsubscribe()
		end
		if gcSubscription then
			if type(gcSubscription) == "function" then
				gcSubscription()
			elseif gcSubscription.unsubscribe then
				gcSubscription:unsubscribe()
			elseif gcSubscription.dispose then
				gcSubscription:dispose()
			end
			gcSubscription = nil
		end
	end

	-- Shared subscription / teardown: stop the source + GC when all downstream observers are gone.
	local refCount = 0
	local function attach(subject)
		return rx.Observable.create(function(observer)
			refCount = refCount + 1
			local sub = subject:subscribe(observer)
			local unsubscribed = false
			return function()
				if unsubscribed then
					return
				end
				unsubscribed = true
				sub:unsubscribe()
				refCount = refCount - 1
				if refCount <= 0 then
					teardown()
				end
			end
		end)
	 end

	local aggregateObservable = attach(aggregateSubject)
	local enrichedObservable = attach(enrichedSubject)
	local expiredObservable = attach(expiredSubject)

	return aggregateObservable, enrichedObservable, expiredObservable
end

return GroupByCore
