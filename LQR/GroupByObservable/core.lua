local rx = require("reactivex")
local Log = require("LQR/util/log").withTag("group")
local DataModel = require("LQR/GroupByObservable/data_model")

local GroupByCore = {}

local VALID_AGG_KEYS = {
	row_count = true,
	count = true,
	sum = true,
	avg = true,
	min = true,
	max = true,
}

local function validateAggregates(aggregateConfig)
	if type(aggregateConfig) ~= "table" then
		return {}
	end
	for key, value in pairs(aggregateConfig) do
		if not VALID_AGG_KEYS[key] then
			Log:warn("groupBy aggregates ignored unknown key '%s'", tostring(key))
		else
			if key == "row_count" and type(value) ~= "boolean" and value ~= nil then
				Log:warn("groupBy aggregates.row_count should be boolean (got %s)", type(value))
			end
			if (key == "count" or key == "sum" or key == "avg" or key == "min" or key == "max")
				and value ~= nil and type(value) ~= "table"
			then
				Log:warn("groupBy aggregates.%s expects a table of paths (got %s)", key, type(value))
			end
		end
	end
	return aggregateConfig
end

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

local function normalizeAggregateEntries(entries, kind)
	local normalized = {}
	if type(entries) ~= "table" then
		return normalized
	end
	for _, entry in ipairs(entries) do
		if type(entry) == "string" then
			normalized[#normalized + 1] = { path = entry }
		elseif type(entry) == "table" then
			local path = entry.path
			if type(path) ~= "string" or path == "" then
				Log:warn("groupBy aggregate '%s' ignored entry with missing path", tostring(kind))
			else
				if entry.distinctFn ~= nil and type(entry.distinctFn) ~= "function" then
					Log:warn("groupBy aggregate '%s' ignored path '%s' (distinctFn must be a function)", tostring(kind),
						tostring(path))
				else
					local alias = entry.alias
					if alias ~= nil and type(alias) ~= "string" then
						Log:warn("groupBy aggregate '%s' alias must be a string (got %s) for path '%s'", tostring(kind),
							type(alias), tostring(path))
						alias = nil
					end
					normalized[#normalized + 1] = {
						path = path,
						alias = alias,
						distinctFn = entry.distinctFn,
					}
				end
			end
		else
			Log:warn("groupBy aggregate '%s' expects string or table entries (got %s)", tostring(kind), type(entry))
		end
	end
	return normalized
end

-- Explainer: normalizeWindow mirrors joinWindow semantics so GC options behave consistently.
-- We intentionally keep gcOnInsert defaulting to true and support periodic GC via gcIntervalSeconds/gcScheduleFn.
local function default_now()
	if os and type(os.time) == "function" then
		return os.time
	end
	return function()
		return 0
	end
end

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
		currentFn = opts.currentFn or default_now(),
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
	aggregateConfig = validateAggregates(aggregateConfig or {})
	local aggregates = {
		rowCount = aggregateConfig.row_count ~= false and #entries or nil,
		count = {},
		sum = {},
		avg = {},
		min = {},
		max = {},
		aliases = {},
	}
	-- Explainer: aliases mirror aggregate outputs onto user-provided paths (e.g., lions.avgHunger)
	-- while we keep the canonical _avg/_sum/... under the source path for downstream joins.

	local function resolveAliasPath(path, alias)
		if not alias or alias == "" then
			return nil
		end
		if alias:match("%.") then
			return alias
		end
		local prefix = path:match("^(.*)%.")
		if prefix and prefix ~= "" then
			return prefix .. "." .. alias
		end
		return alias
	end

	local function distinctKey(entry, row, cache)
		if not entry.distinctFn then
			return true, false
		end
		local ok, keyOrErr = pcall(entry.distinctFn, row)
		if not ok then
			Log:warn("groupBy distinctFn for '%s' errored - %s", tostring(entry.path), tostring(keyOrErr))
			return false, true
		end
		if keyOrErr == nil then
			return false, false
		end
		local keyType = type(keyOrErr)
		if keyType ~= "string" and keyType ~= "number" and keyType ~= "boolean" then
			Log:warn("groupBy distinctFn for '%s' returned non-primitive (%s); aggregate skipped", tostring(entry.path),
				keyType)
			return false, true
		end
		if cache[keyOrErr] then
			return false, false
		end
		cache[keyOrErr] = true
		return true, false
	end

	local function accumulateNumeric(kind, entriesToUse)
		local normalized = normalizeAggregateEntries(entriesToUse, kind)
		for _, entry in ipairs(normalized) do
			local total = 0
			local seen = 0
			local minVal
			local maxVal
			local seenKeys = entry.distinctFn and {} or nil
			local skip = false
			-- NOTE: distinctFn uses a per-entry seenKeys table scoped to this recompute to avoid leaks.
			-- We treat non-primitive distinct keys as fatal for that aggregate entry and warn.

			for _, sourceEntry in ipairs(entries) do
				local row = sourceEntry.value
				local v = getNested(row, entry.path)
				if type(v) == "number" then
					local shouldCount = true
					if seenKeys then
						local allow, fatal = distinctKey(entry, row, seenKeys)
						if fatal then
							skip = true
							break
						end
						if not allow then
							shouldCount = false
						end
					end
					if shouldCount then
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
			end

			if not skip then
				if seen == 0 then
					Log:warn("groupBy aggregate '%s' ignored path '%s' (missing or non-numeric)", kind, entry.path)
				end
				if kind == "sum" and seen > 0 then
					aggregates.sum[entry.path] = total
					local aliasPath = resolveAliasPath(entry.path, entry.alias)
					if aliasPath then
						aggregates.aliases[aliasPath] = total
					end
				elseif kind == "min" and seen > 0 then
					aggregates.min[entry.path] = minVal
					local aliasPath = resolveAliasPath(entry.path, entry.alias)
					if aliasPath then
						aggregates.aliases[aliasPath] = minVal
					end
				elseif kind == "max" and seen > 0 then
					aggregates.max[entry.path] = maxVal
					local aliasPath = resolveAliasPath(entry.path, entry.alias)
					if aliasPath then
						aggregates.aliases[aliasPath] = maxVal
					end
				elseif kind == "avg" then
					local aliasPath = resolveAliasPath(entry.path, entry.alias)
					if seen > 0 then
						local avgVal = total / seen
						aggregates.avg[entry.path] = avgVal
						if aliasPath then
							aggregates.aliases[aliasPath] = avgVal
						end
					else
						aggregates.avg[entry.path] = nil
						if aliasPath then
							aggregates.aliases[aliasPath] = nil
						end
					end
				end
			end
		end
	end

	accumulateNumeric("sum", aggregateConfig.sum)
	accumulateNumeric("avg", aggregateConfig.avg)
	accumulateNumeric("min", aggregateConfig.min)
	accumulateNumeric("max", aggregateConfig.max)

	local function accumulateCount(entriesToUse)
		local normalized = normalizeAggregateEntries(entriesToUse, "count")
		local hadExplicit = false
		for _, entry in ipairs(normalized) do
			hadExplicit = true
			local seen = 0
			local seenKeys = entry.distinctFn and {} or nil
			local skip = false
			for _, sourceEntry in ipairs(entries) do
				local row = sourceEntry.value
				local v = getNested(row, entry.path)
				if v ~= nil then
					local shouldCount = true
					if seenKeys then
						local allow, fatal = distinctKey(entry, row, seenKeys)
						if fatal then
							skip = true
							break
						end
						if not allow then
							shouldCount = false
						end
					end
					if shouldCount then
						seen = seen + 1
					end
				end
			end
			if not skip then
				if seen == 0 then
					Log:warn("groupBy count ignored path '%s' (missing)", entry.path)
				end
				aggregates.count[entry.path] = seen
				local aliasPath = resolveAliasPath(entry.path, entry.alias)
				if aliasPath then
					aggregates.aliases[aliasPath] = seen
				end
			end
		end
		return hadExplicit
	end

	if aggregates.rowCount then
		local hadExplicit = accumulateCount(aggregateConfig.count)
		if not hadExplicit then
			-- Default: count rows per schema (id presence) if no explicit count paths supplied.
			for _, entry in ipairs(entries) do
				local row = entry.value
				if type(row) == "table" then
					for schemaName, record in pairs(row) do
						if schemaName ~= "_raw_result" and schemaName ~= "RxMeta" and type(record) == "table" then
							local key = schemaName .. ".id"
							local current = aggregates.count[key] or 0
							if record.id ~= nil or (record.RxMeta and record.RxMeta.id ~= nil) then
								aggregates.count[key] = current + 1
							end
						end
					end
				end
			end
		end
	end

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
							origin = "group",
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
			Log:warn("groupBy keySelector errored - %s", tostring(keyOrErr))
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
						origin = "group",
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
							origin = "group",
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
