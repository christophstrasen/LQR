-- High-level fluent query builder (joins + selection) without manual chain wiring.
---@class QueryBuilder
---@field private _rootSource rx.Observable
---@field private _rootSchemas table|nil
---@field private _steps table
---@field private _selection table|nil
---@field private _schemaNames table|nil
---@field private _built table|nil
---@field private _defaultJoinWindow table|nil
	---@field private _scheduler any
	---@field private _vizHook fun(context:table):table|nil
	---@field private _wherePredicate fun(row:table):boolean|nil
	---@field private _finalWherePredicates table|nil
	---@field private _finalTap fun(value:any)|nil
	local rx = require("reactivex")
local JoinObservable = require("LQR/JoinObservable")
local Result = require("LQR/JoinObservable/result")
local Log = require("LQR/util/log").withTag("query")
local GroupByObservable = require("LQR/GroupByObservable")
local DistinctObservable = require("LQR/Query/distinct_observable")
local Schema = require("LQR/JoinObservable/schema")
local TableUtil = require("LQR/util/table")
local TimeUtil = require("LQR/util/time")

local DEFAULT_WINDOW_COUNT = 1000
local DEFAULT_PER_KEY_BUFFER_SIZE = 10
local schedulerOverride = nil
local defaultJoinWindowOverride = nil

local function warnUnknownKeys(tbl, allowed, label)
	if type(tbl) ~= "table" then
		return false
	end
	local unknown = {}
	for key in pairs(tbl) do
		if not allowed[key] then
			unknown[#unknown + 1] = tostring(key)
		end
	end
		if #unknown > 0 then
			Log:warn("%s ignored unknown key(s) - %s", label, table.concat(unknown, ", "))
			return true
		end
		return false
	end

local function validateCountWindow(window, label)
	if not window then
		return
	end
	local count = window.count or window.maxItems
		if count ~= nil and (type(count) ~= "number" or count <= 0) then
			Log:warn("%s - count/maxItems should be a positive number; defaulting to %d", label, DEFAULT_WINDOW_COUNT)
			window.count = DEFAULT_WINDOW_COUNT
			window.maxItems = nil
		end
	end

local function validateTimeWindow(window, label)
	if not window then
		return
	end
	local wantsTime = window.mode == "time" or window.mode == "interval" or window.time ~= nil or window.offset ~= nil
	if not wantsTime then
		return
	end
	if window.field ~= nil and type(window.field) ~= "string" then
		Log:warn("%s - field should be a string; defaulting to 'sourceTime'", label)
		window.field = "sourceTime"
	end
	local offset = window.time or window.offset
	if offset ~= nil and (type(offset) ~= "number" or offset < 0) then
		Log:warn("%s - time/offset should be a non-negative number; defaulting to 0", label)
		window.time = 0
		window.offset = nil
	end
	if window.currentFn ~= nil and type(window.currentFn) ~= "function" then
		Log:warn("%s - currentFn should be a function; ignoring provided value", label)
		window.currentFn = nil
	end
end

local function validateWindowMode(window, label)
	if not window or not window.mode then
		return
	end
	local mode = window.mode
	if mode ~= "count" and mode ~= "time" and mode ~= "interval" and mode ~= "predicate" then
		Log:warn("%s - unsupported mode '%s'; defaulting to count/time auto-detection", label, tostring(mode))
		window.mode = nil
	end
end

local VALID_JOIN_WINDOW_KEYS = {
	count = true,
	maxItems = true,
	gcOnInsert = true,
	gcIntervalSeconds = true,
	gcScheduleFn = true,
	mode = true,
	field = true,
	time = true,
	offset = true,
	currentFn = true,
}

local VALID_GROUP_WINDOW_KEYS = {
	count = true,
	time = true,
	field = true,
	currentFn = true,
	gcOnInsert = true,
	gcIntervalSeconds = true,
	gcScheduleFn = true,
}

local QueryBuilder = {}
QueryBuilder.__index = QueryBuilder

local function hasAnyKey(tbl)
	local hasKey = false
	for _ in pairs(tbl or {}) do
		hasKey = true
	end
	return hasKey
end

-- Explainer: union builds a sorted de-duped list so describe/select stay stable.
local function union(left, right)
	local set, output = {}, {}
	for _, name in ipairs(left or {}) do
		if not set[name] then
			set[name] = true
			output[#output + 1] = name
		end
	end
	for _, name in ipairs(right or {}) do
		if name and not set[name] then
			set[name] = true
			output[#output + 1] = name
		end
	end
	table.sort(output)
	return output
end

local function selectionTargets(selection)
	if not selection then
		return nil
	end
	local targets = {}
	for _, value in ipairs(selection) do
		if type(value) == "string" and value ~= "" then
			targets[#targets + 1] = value
		end
	end
	for key, value in pairs(selection) do
		if type(key) ~= "number" and type(value) == "string" and value ~= "" then
			targets[#targets + 1] = value
		end
	end
	if #targets == 0 then
		return nil
	end
	return union(targets)
end

-- Explainer: schemaSet enables O(1) membership checks when filtering flattened schemas.
local function schemaSet(names)
	if not names then
		return nil
	end
	local set = {}
	for _, name in ipairs(names) do
		if type(name) == "string" and name ~= "" then
			set[name] = true
		end
	end
	return hasAnyKey(set) and set or nil
end

-- Explainer: filterFromMap narrows participation to schemas that have selectors configured.
local function filterFromMap(map, known)
	if not map then
		return nil
	end
	local set = {}
	if known then
		for name in pairs(known) do
			if map[name] ~= nil then
				set[name] = true
			end
		end
	end
	if hasAnyKey(set) then
		return set
	end
	for name in pairs(map) do
		set[name] = true
	end
	return set
end

local function isJoinResult(value)
	return getmetatable(value) == Result
end

local function isQueryBuilder(value)
	return getmetatable(value) == QueryBuilder
end

local function isObservable(value)
	return type(value) == "table"
		and type(value.subscribe) == "function"
		and type(value.map) == "function"
		and type(value.filter) == "function"
end

local function normalizeSourceArg(source, opts)
	local schemaName
	if type(opts) == "string" then
		schemaName = opts
	elseif type(opts) == "table" then
		schemaName = opts.schema or opts.name or opts.as
	end
	if isQueryBuilder(source) or isObservable(source) then
		return source, schemaName
	end
	-- Explainer: allow wrapper sources to expose getLQR/asRx so Query.from can accept stream objects directly.
	if type(source) == "table" then
		local getLQR = source.getLQR
		if type(getLQR) == "function" then
			local ok, candidate = pcall(getLQR, source)
			if ok and isQueryBuilder(candidate) then
				return candidate, schemaName
			end
		end
		local asRx = source.asRx
		if type(asRx) == "function" then
			local ok, candidate = pcall(asRx, source)
			if ok and isObservable(candidate) then
				return candidate, schemaName
			end
		end
	end
	return source, schemaName
end

local function ensureId(meta, record, opts)
	if not meta then
		return
	end
	if meta.id ~= nil then
		return
	end
	opts = opts or {}
	if type(opts.idSelector) == "function" then
		local ok, value = pcall(opts.idSelector, record)
		if ok then
			meta.id = value
			meta.idField = meta.idField or opts.idField or "custom"
			return
		end
	end
	if opts.idField and type(record) == "table" then
		meta.id = record[opts.idField]
		meta.idField = meta.idField or opts.idField
		return
	end
	if meta.groupKey ~= nil then
		meta.id = meta.groupKey
		meta.idField = meta.idField or "groupKey"
	end
end

local function default_now()
	return TimeUtil.defaultNowFn()
end

local function maybeResetTime(record, opts)
	if not opts or not opts.resetTime then
		return
	end
	if type(record) ~= "table" then
		return
	end
	local field = opts.timeField or "sourceTime"
	local currentFn = opts.currentFn or default_now()
	record[field] = currentFn()
end

local function buildJoinResultFromEnriched(row, opts)
	if type(row) ~= "table" then
		return nil
	end
	local result = Result.new()
	for key, value in pairs(row) do
		if key ~= "RxMeta" and type(value) == "table" then
			local meta = value.RxMeta
			if type(meta) == "table" and type(meta.schema) == "string" and meta.schema ~= "" then
				ensureId(meta, value, opts)
				maybeResetTime(value, opts)
				result:attach(meta.schema, value)
			end
		end
	end
	return result
end

local function adaptInput(source, opts)
	local schemaName = type(opts) == "string" and opts
		or (type(opts) == "table" and (opts.schema or opts.name or opts.as))

	if getmetatable(source) == QueryBuilder then
		local built = source:_build()
		return adaptInput(built.observable, opts)
	end

	local function adaptValue(value)
		if isJoinResult(value) then
			return value
		end
		if type(value) ~= "table" then
			return nil
		end
		local meta = value.RxMeta
		if type(meta) ~= "table" then
			return nil
		end
		local shape = meta.shape or "record"
		if schemaName and shape ~= "join_result" then
			meta.schema = schemaName
		end

		if shape == "group_enriched" then
			return buildJoinResultFromEnriched(value, opts)
		end

		if shape == "group_aggregate" or shape == "record" or meta.schema then
			ensureId(meta, value, opts)
			maybeResetTime(value, opts)
			local r = Result.new()
			return r:attach(meta.schema, value)
		end

		return nil
	end

	local adapted = source:map(adaptValue):filter(function(v)
		return v ~= nil
	end)

	local inferredSchemas = schemaName and { schemaName } or nil
	return adapted, inferredSchemas
end

-- Explainer: makeEmptyObservable offers a no-op observable for missing side channels.
local function makeEmptyObservable()
	return rx.Observable.create(function(observer)
		observer:onCompleted()
		return function() end
	end)
end

-- Explainer: mergeObservables fans in multiple observables while propagating completion/error correctly.
local function mergeObservables(observables)
	if not observables or #observables == 0 then
		return makeEmptyObservable()
	end

	return rx.Observable.create(function(observer)
		local remaining = #observables
		local closed = false
		local subscriptions = {}

		local function tryComplete()
			if closed then
				return
			end
			remaining = remaining - 1
			if remaining <= 0 then
				closed = true
				observer:onCompleted()
			end
		end

		for i, observable in ipairs(observables) do
			subscriptions[i] = observable:subscribe(function(value)
				if not closed then
					observer:onNext(value)
				end
			end, function(err)
				if closed then
					return
				end
				closed = true
				observer:onError(err)
			end, tryComplete)
		end

		return function()
			for i = 1, #subscriptions do
				local sub = subscriptions[i]
				if sub and sub.unsubscribe then
					sub:unsubscribe()
				elseif type(sub) == "function" then
					sub()
				end
			end
		end
	end)
end

local function warnIfBuilt(builder, verb)
	if builder._built then
		Log:warn(
			"Query.%s called on a builder that has already been built; this creates a new query and will not affect existing subscriptions",
			tostring(verb)
		)
	end
end

-- Explainer: buildSelectionMap normalizes selection into schema->alias mapping for reuse.
local function buildSelectionMap(selection)
	if not selection then
		return nil
	end
	if type(selection) ~= "table" then
		Log:warn("selectSchemas ignored invalid selection of type %s", type(selection))
		return nil
	end

	local mapping = {}
	local has = false

	-- Array part (prefer ipairs if available)
	if type(ipairs) == "function" then
		for _, schema in ipairs(selection) do
			if type(schema) == "string" and schema ~= "" then
				mapping[schema] = schema
				has = true
			end
		end
	else
		for i = 1, #selection do
			local schema = selection[i]
			if type(schema) == "string" and schema ~= "" then
				mapping[schema] = schema
				has = true
			end
		end
	end

	-- Hash part (only if pairs is available)
	if type(pairs) == "function" then
		for key, value in pairs(selection) do
			if type(key) ~= "number" and type(value) == "string" and value ~= "" then
				mapping[key] = value
				has = true
			end
		end
	end

	return has and mapping or nil
end

-- Explainer: flattenRecords turns records or JoinResults into per-schema records, tagging lineage.
local function flattenRecords(observable, allowedSchemas)
	local function allow(schemaName)
		if not allowedSchemas or schemaName == nil then
			return true
		end
		return allowedSchemas[schemaName] == true
	end

	return rx.Observable.create(function(observer)
		local subscription
		subscription = observable:subscribe(function(value)
			if isJoinResult(value) then
				for _, schemaName in ipairs(value:schemaNames()) do
					local record = value:get(schemaName)
					if record and allow(schemaName) then
						local copy = Result.shallowCopyRecord(record, schemaName) or record
						if type(copy) == "table" then
							copy._JoinParentResult = value
						end
						observer:onNext(copy)
					end
				end
			elseif type(value) == "table" then
				local schemaName = value.RxMeta and value.RxMeta.schema
				if allow(schemaName) then
					observer:onNext(value)
				end
			else
				Log:warn("Query builder dropped emission of type %s (expected table or JoinResult)", type(value))
			end
		end, function(err)
			observer:onError(err)
		end, function()
			observer:onCompleted()
		end)

		return function()
			if subscription then
				subscription:unsubscribe()
			end
		end
	end)
end

-- Explainer: selectorFromSchemas drives per-schema key lookups with soft warnings for gaps.
local function selectorFromSchemas(map)
	local missingWarned = {}
	local function selector(entry, _, schemaName)
		local field = schemaName and map[schemaName]
		if not field then
			if schemaName and not missingWarned[schemaName] then
				missingWarned[schemaName] = true
				Log:warn("Query.on missing selector for schema '%s'", schemaName)
			end
			return nil
		end
		local value = entry and entry[field]
		if value == nil and schemaName and not missingWarned[schemaName .. "::field"] then
			missingWarned[schemaName .. "::field"] = true
			Log:warn("Query.on('%s') missing field '%s'", schemaName, field)
		end
		return value
	end
	return selector
end

-- Explainer: normalizeKeySelector converts builder specs into the callable expected by the core join.
local function normalizeKeySelector(step)
	local spec = step.keySpec
	assert(spec and spec.kind == "schemas", "on(...) is required for join keys")
	local normalized = {}
	local bufferSizes = {}
	local oneShotSchemas = {}
	for schema, value in pairs(spec.map) do
		if type(schema) ~= "string" or schema == "" then
			error("on keys must be non-empty schema names")
		end
		local field = value
		local perKeyBufferSize
		if type(value) == "table" then
			field = value.field or value.selector and value.field
				if value.bufferSize ~= nil and value.perKeyBufferSize ~= nil then
					Log:warn("on[%s] - both bufferSize and perKeyBufferSize provided; bufferSize wins", tostring(schema))
				end
			perKeyBufferSize = value.bufferSize or value.perKeyBufferSize
			local oneShot = value.oneShot
			if oneShot == true then
				oneShotSchemas[schema] = true
			elseif oneShot == false then
				oneShotSchemas[schema] = false
			end
		end
		if type(field) ~= "string" or field == "" then
			error(("on entry for '%s' must define a field (string)"):format(schema))
		end
		normalized[schema] = field
		if perKeyBufferSize then
			assert(type(perKeyBufferSize) == "number", "perKeyBufferSize must be a positive number")
				if perKeyBufferSize < 1 then
					Log:warn("on[%s] - bufferSize < 1; clamping to 1", tostring(schema))
					perKeyBufferSize = 1
				end
			bufferSizes[schema] = perKeyBufferSize
	end
	end
	return selectorFromSchemas(normalized), bufferSizes, hasAnyKey(oneShotSchemas) and oneShotSchemas or nil
end

-- Explainer: normalizeJoinWindow defaults to a large count join window and threads scheduler into GC if available.
local function normalizeJoinWindow(step, defaultJoinWindow, scheduler)
	local joinWindow = step.joinWindow or defaultJoinWindow
	if not joinWindow then
		joinWindow = { count = DEFAULT_WINDOW_COUNT }
	end
	validateWindowMode(joinWindow, "joinWindow")
	validateCountWindow(joinWindow, "joinWindow")
	validateTimeWindow(joinWindow, "joinWindow")
	warnUnknownKeys(joinWindow, VALID_JOIN_WINDOW_KEYS, "joinWindow")

	if joinWindow.mode == "count" and not joinWindow.count then
		joinWindow = {
			count = joinWindow.maxItems or DEFAULT_WINDOW_COUNT,
			gcOnInsert = joinWindow.gcOnInsert,
			gcIntervalSeconds = joinWindow.gcIntervalSeconds,
			gcScheduleFn = joinWindow.gcScheduleFn,
		}
	end

	if joinWindow.count or joinWindow.maxItems then
		return {
			joinWindow = {
				mode = "count",
				maxItems = joinWindow.count or joinWindow.maxItems,
			},
			gcOnInsert = joinWindow.gcOnInsert,
			gcIntervalSeconds = joinWindow.gcIntervalSeconds,
			gcScheduleFn = joinWindow.gcScheduleFn,
		}
	end

	local scheduleFn = joinWindow.gcScheduleFn
	if not scheduleFn and scheduler and scheduler.schedule then
		scheduleFn = function(delaySeconds, fn)
			return scheduler:schedule(fn, delaySeconds)
		end
	end

	return {
		joinWindow = {
			mode = "interval",
			field = joinWindow.field or "sourceTime",
			offset = joinWindow.time or joinWindow.offset or 0,
			currentFn = joinWindow.currentFn or default_now(),
		},
		gcOnInsert = joinWindow.gcOnInsert,
		gcIntervalSeconds = joinWindow.gcIntervalSeconds,
		gcScheduleFn = scheduleFn,
	}
end

-- Explainer: applySelectionToResult reprojects schemas after the join pipeline if requested.
local function applySelectionToResult(result, selection)
	if not selection or not isJoinResult(result) then
		return result
	end
	return Result.selectSchemas(result, selection)
end

-- Explainer: reattachParentSchemas ensures chained joins keep access to upstream schemas.
local function reattachParentSchemas(result)
	if not isJoinResult(result) then
		return result
	end

	local parent
	for _, schemaName in ipairs(result:schemaNames()) do
		local record = result:get(schemaName)
		if type(record) == "table" and record._JoinParentResult then
			parent = record._JoinParentResult
			record._JoinParentResult = nil
			break
		end
	end

	if not parent or not isJoinResult(parent) then
		return result
	end

	local combined = result:clone()
	for _, schemaName in ipairs(parent:schemaNames()) do
		if not combined:get(schemaName) then
			combined:attachFrom(parent, schemaName)
		end
	end

	return combined
end

-- Explainer: applySelectionToExpired mirrors selection onto expired side-channel packets.
local function applySelectionToExpired(expired, selection)
	if not selection then
		return expired
	end
	local mapping = buildSelectionMap(selection)
	if not mapping then
		return expired
	end

	return expired:map(function(packet)
		if not packet or not packet.result or not isJoinResult(packet.result) then
			return packet
		end
		local selected = Result.selectSchemas(packet.result, selection)
		local newSchema = mapping[packet.schema]
		if not newSchema then
			return nil
		end
		return {
			schema = newSchema,
			key = packet.key,
			reason = packet.reason,
			result = selected,
		}
	end):filter(function(packet)
		return packet ~= nil
	end)
end

-- Explainer: buildRowView exposes schemas as table fields and supplies _raw_result for escape hatches.
-- This keeps WHERE predicates simple: every schema key is present (empty table if absent)
-- and users can still reach the raw JoinResult when needed.
local function buildRowView(result, schemaNames)
	if not isJoinResult(result) then
		return nil
	end
	local row = {
		_raw_result = result,
	}
	local names = schemaNames or result:schemaNames()
	if names then
		for _, schemaName in ipairs(names) do
			if type(schemaName) == "string" and schemaName ~= "" then
				row[schemaName] = result:get(schemaName) or {}
			end
		end
	end
	return row
end

-- Explainer: toJoinResult wraps raw schema-tagged records for selection-only flows.
-- The builder downstream always expects JoinResult; this keeps single-source queries consistent.
local function toJoinResult(value)
	if isJoinResult(value) then
		return value
	end
	if type(value) == "table" then
		local schemaName = value.RxMeta and value.RxMeta.schema
		if schemaName then
			local temp = Result.new()
			return temp:attach(schemaName, value)
		end
	end
	return nil
end

local function summarizeRowIds(row, schemaNames)
	if not row then
		return "no-row"
	end
	local summary = {}
	local names = schemaNames or {}
	for _, schemaName in ipairs(names) do
		local entry = row[schemaName]
		local id = nil
		if type(entry) == "table" then
			id = entry.id or (entry.RxMeta and entry.RxMeta.id) or (entry.RxMeta and entry.RxMeta.joinKey)
		end
		summary[#summary + 1] = string.format("%s-%s", tostring(schemaName), tostring(id))
		if #summary >= 3 then
			break
		end
	end
	if #summary == 0 then
		return "no-schemas"
	end
	return table.concat(summary, ",")
end

	function QueryBuilder:_clone()
		local copy = setmetatable({}, QueryBuilder)
	copy._rootSource = self._rootSource
	copy._rootSchemas = self._rootSchemas and TableUtil.shallowArray(self._rootSchemas) or nil
	copy._steps = {}
	for i = 1, #self._steps do
		local step = self._steps[i]
		local stepCopy = TableUtil.shallowCopy(step)
		if type(step.keySpec) == "table" then
			stepCopy.keySpec = TableUtil.shallowCopy(step.keySpec)
		end
		copy._steps[i] = stepCopy
	end
	copy._distinctSteps = self._distinctSteps and TableUtil.shallowArray(self._distinctSteps) or {}
	copy._selection = self._selection
	copy._schemaNames = self._schemaNames and TableUtil.shallowArray(self._schemaNames) or nil
	copy._defaultJoinWindow = self._defaultJoinWindow
	copy._scheduler = self._scheduler
	copy._vizHook = self._vizHook
	copy._wherePredicate = self._wherePredicate
	copy._havingPredicate = self._havingPredicate
	copy._group = self._group
		copy._groupWindow = self._groupWindow
		copy._aggregates = self._aggregates
		copy._finalWherePredicates = self._finalWherePredicates and TableUtil.shallowArray(self._finalWherePredicates) or nil
		copy._finalTap = self._finalTap
		return copy
	end

-- Explainer: ensureStep prevents configuring keys/joinWindow before any join is staged.
local function ensureStep(builder)
	if #builder._steps == 0 then
		error("Call innerJoin/leftJoin before using/joinWindow")
	end
end

-- Explainer: hasMappingFor checks map coverage for either side to avoid silent key omissions.
local function hasMappingFor(map, schemas)
	if not schemas or #schemas == 0 then
		return false
	end
	for _, schemaName in ipairs(schemas) do
		if map[schemaName] ~= nil then
			return true
		end
	end
	return false
end

-- Explainer: ensureUsingCoverage enforces at least one mapping on each side when configuring using().
local function ensureUsingCoverage(map, leftSchemas, rightSchemas)
	if leftSchemas and #leftSchemas > 0 and not hasMappingFor(map, leftSchemas) then
		error("using must map at least one left-side schema")
	end
	if rightSchemas and #rightSchemas > 0 and not hasMappingFor(map, rightSchemas) then
		error("using must map at least one right-side schema")
	end
end

local function deriveSchemasFromSelection(selection)
	local targets = selectionTargets(selection)
	return targets
end

local function resolveBufferSize(bufferSizes, schemas)
	if not schemas or not bufferSizes then
		return DEFAULT_PER_KEY_BUFFER_SIZE
	end
	local size = nil
	for _, name in ipairs(schemas) do
		local configured = bufferSizes[name]
		if configured and (not size or configured > size) then
			size = configured
		end
	end
	return size or DEFAULT_PER_KEY_BUFFER_SIZE
end

local function resolveDefaultJoinWindow(builder)
	return builder._defaultJoinWindow or defaultJoinWindowOverride
end

local function collectPrimarySchemas(builder, set)
	set = set or {}
	if builder._rootSchemas then
		for _, name in ipairs(builder._rootSchemas) do
			if name then
				set[name] = true
			end
		end
	end
	for _, step in ipairs(builder._steps) do
		local source = step.source
		if getmetatable(source) == QueryBuilder then
			collectPrimarySchemas(source, set)
		elseif step.sourceSchema then
			set[step.sourceSchema] = true
		elseif type(source) == "table" and source.schemaName then
			set[source.schemaName] = true
		end
	end
	return set
end

local function resolveObservable(source, opts)
	if isQueryBuilder(source) then
		local built = source:_build()
		return built.observable, built.expired, source._schemaNames
	end
	if isObservable(source) then
		local adapted, schemas = adaptInput(source, opts)
		return adapted, nil, schemas
	end
	return source, nil, nil
end

local function applyDistinctSteps(current, distinctSteps, afterStepIndex, expiredStreams, scheduler)
	if not distinctSteps then
		return current
	end
	for _, step in ipairs(distinctSteps) do
		if step.afterStepIndex == afterStepIndex then
			local distinctObservable, expired = DistinctObservable.createDistinctObservable(current, {
				schema = step.schema,
				by = step.keySelector,
				field = step.keySelector,
				window = step.window,
				scheduler = scheduler,
			})
			if expired then
				expiredStreams[#expiredStreams + 1] = expired
			end
			current = distinctObservable
		end
	end
	return current
end

---Internal helper to build a new QueryBuilder from a source.
---@param source rx.Observable
---@param opts table|string|nil
---@return QueryBuilder
local function newBuilder(source, opts)
	local normalizedSource, schemaName = normalizeSourceArg(source, opts)
	assert(
		normalizedSource and (isQueryBuilder(normalizedSource) or isObservable(normalizedSource)),
		"Query.from expects a reactivex observable, QueryBuilder, or source exposing getLQR/asRx"
	)
	local observable, inferredSchemas = adaptInput(normalizedSource, opts)
	local builder = setmetatable({}, QueryBuilder)
	builder._rootSource = observable
	builder._rootSchemas = inferredSchemas or (schemaName and { schemaName }) or nil
	builder._schemaNames = builder._rootSchemas and TableUtil.shallowArray(builder._rootSchemas) or nil
	builder._steps = {}
	builder._distinctSteps = {}
	builder._defaultJoinWindow = defaultJoinWindowOverride
	builder._scheduler = schedulerOverride
	builder._vizHook = nil
	builder._wherePredicate = nil
	return builder
end

function QueryBuilder:_addStep(joinType, source, opts)
	warnIfBuilt(self, joinType .. "Join")
	local observable, schemaName = normalizeSourceArg(source, opts)
	local nextBuilder = self:_clone()
	nextBuilder._steps[#nextBuilder._steps + 1] = {
		joinType = joinType,
		source = observable,
		sourceSchema = schemaName,
		sourceOpts = type(opts) == "table" and opts or nil,
	}
	if schemaName then
		nextBuilder._schemaNames = union(nextBuilder._schemaNames, { schemaName })
	end
	return nextBuilder
end

---Adds an inner join to the builder.
---@param source rx.Observable|QueryBuilder
---@param opts table|string|nil
---@return QueryBuilder
function QueryBuilder:innerJoin(source, opts)
	return self:_addStep("inner", source, opts)
end

---Adds a left join to the builder.
---@param source rx.Observable|QueryBuilder
---@param opts table|string|nil
---@return QueryBuilder
function QueryBuilder:leftJoin(source, opts)
	return self:_addStep("left", source, opts)
end

---Adds a right join to the builder.
---@param source rx.Observable|QueryBuilder
---@param opts table|string|nil
---@return QueryBuilder
function QueryBuilder:rightJoin(source, opts)
	return self:_addStep("right", source, opts)
end

---Adds a full/outer join to the builder.
---@param source rx.Observable|QueryBuilder
---@param opts table|string|nil
---@return QueryBuilder
function QueryBuilder:outerJoin(source, opts)
	return self:_addStep("outer", source, opts)
end

---Adds an anti-left join (emit only unmatched left rows) to the builder.
---@param source rx.Observable|QueryBuilder
---@param opts table|string|nil
---@return QueryBuilder
function QueryBuilder:antiLeftJoin(source, opts)
	return self:_addStep("anti_left", source, opts)
end

---Adds an anti-right join (emit only unmatched right rows) to the builder.
---@param source rx.Observable|QueryBuilder
---@param opts table|string|nil
---@return QueryBuilder
function QueryBuilder:antiRightJoin(source, opts)
	return self:_addStep("anti_right", source, opts)
end

---Adds an anti-outer join (emit unmatched from both sides) to the builder.
---@param source rx.Observable|QueryBuilder
---@param opts table|string|nil
---@return QueryBuilder
function QueryBuilder:antiOuterJoin(source, opts)
	return self:_addStep("anti_outer", source, opts)
end

---Configures grouping key function (aggregate view).
---@param groupNameOrKeyFn string|fun(row:table):string|number|boolean
---@param keyFn fun(row:table):string|number|boolean|nil
---@return QueryBuilder
function QueryBuilder:groupBy(groupNameOrKeyFn, keyFn)
	warnIfBuilt(self, "groupBy")
	local groupName = nil
	if type(groupNameOrKeyFn) == "string" then
		groupName = groupNameOrKeyFn
	else
		keyFn = groupNameOrKeyFn
	end
	assert(type(keyFn) == "function", "groupBy expects a function keyFn")
	local nextBuilder = self:_clone()
	nextBuilder._group = {
		keyFn = keyFn,
		groupName = groupName,
		view = "aggregate",
	}
	return nextBuilder
end

---Configures grouping key function (enriched event view).
---@param groupNameOrKeyFn string|fun(row:table):string|number|boolean
---@param keyFn fun(row:table):string|number|boolean|nil
---@return QueryBuilder
function QueryBuilder:groupByEnrich(groupNameOrKeyFn, keyFn)
	warnIfBuilt(self, "groupByEnrich")
	local groupName = nil
	if type(groupNameOrKeyFn) == "string" then
		groupName = groupNameOrKeyFn
	else
		keyFn = groupNameOrKeyFn
	end
	assert(type(keyFn) == "function", "groupByEnrich expects a function keyFn")
	local nextBuilder = self:_clone()
	nextBuilder._group = {
		keyFn = keyFn,
		groupName = groupName,
		view = "enriched",
	}
	return nextBuilder
end

---Configures the group window (time- or count-based).
---@param window table
---@return QueryBuilder
function QueryBuilder:groupWindow(window)
	assert(type(window) == "table", "groupWindow expects a table")
	warnIfBuilt(self, "groupWindow")
	local nextBuilder = self:_clone()
	nextBuilder._groupWindow = window
	return nextBuilder
end

---Declares which aggregates to compute.
---@param aggregates table
---@return QueryBuilder
function QueryBuilder:aggregates(aggregates)
	assert(type(aggregates) == "table", "aggregates expects a table")
	warnIfBuilt(self, "aggregates")
	local nextBuilder = self:_clone()
	nextBuilder._aggregates = aggregates
	return nextBuilder
end

---Applies a HAVING-style predicate over the current view (aggregate or enriched).
---@param predicate fun(row:table):boolean
---@return QueryBuilder
function QueryBuilder:having(predicate)
	assert(type(predicate) == "function", "having expects a function predicate")
	warnIfBuilt(self, "having")
	if not self._group then
		error("having requires groupBy/groupByEnrich to be configured first")
	end
	local nextBuilder = self:_clone()
	nextBuilder._havingPredicate = predicate
	return nextBuilder
end

---Attaches a visualization hook (optional, no-op in normal runs).
---@param vizHook fun(context:table):table|nil
---@return QueryBuilder
function QueryBuilder:withVisualizationHook(vizHook)
	if vizHook ~= nil then
		assert(type(vizHook) == "function", "withVisualizationHook expects a function or nil")
	end
	warnIfBuilt(self, "withVisualizationHook")
	local nextBuilder = self:_clone()
	nextBuilder._vizHook = vizHook
	return nextBuilder
end

---Sets a per-query default join window applied to any join without its own joinWindow.
---@param joinWindow table|nil
---@return QueryBuilder
function QueryBuilder:withDefaultJoinWindow(joinWindow)
	if joinWindow ~= nil then
		assert(type(joinWindow) == "table", "withDefaultJoinWindow expects a table or nil")
	end
	warnIfBuilt(self, "withDefaultJoinWindow")
	local nextBuilder = self:_clone()
	nextBuilder._defaultJoinWindow = joinWindow
	return nextBuilder
end

		---Attaches a tap that fires on every final emission (after finalWhere).
	---@param finalTap fun(value:any)|nil
	---@return QueryBuilder
		function QueryBuilder:finalTap(finalTap)
			if finalTap ~= nil then
				assert(type(finalTap) == "function", "finalTap expects a function or nil")
			end
			warnIfBuilt(self, "finalTap")
			local nextBuilder = self:_clone()
			if finalTap == nil then
				nextBuilder._finalTap = nil
			else
				local previous = nextBuilder._finalTap
				if previous ~= nil then
					nextBuilder._finalTap = function(value)
						previous(value)
						finalTap(value)
					end
				else
					nextBuilder._finalTap = finalTap
				end
			end
			return nextBuilder
		end

---Configures explicit schema->field mappings for join keys.
---@param map table
---@return QueryBuilder
function QueryBuilder:using(map)
	assert(type(map) == "table", "using expects a table")
	warnIfBuilt(self, "using")
	ensureStep(self)
	local hasEntries = hasAnyKey(map)
	assert(hasEntries, "using expects at least one mapping")
	for schemaName, selector in pairs(map) do
		assert(type(schemaName) == "string" and schemaName ~= "", "using keys must be non-empty schema names")
		local selectorType = type(selector)
		assert(
			selectorType == "string" or selectorType == "table",
			("using[%s] must be a string field name or table"):format(schemaName)
		)
	end
	local nextBuilder = self:_clone()
	local step = nextBuilder._steps[#nextBuilder._steps]
	local rightSchemas = step and step.sourceSchema and { step.sourceSchema } or nil
	if step and getmetatable(step.source) == QueryBuilder then
		rightSchemas = step.source._schemaNames or rightSchemas
	end
	if map then
		local known = {}
		if self._schemaNames then
			for _, name in ipairs(self._schemaNames) do
				known[name] = true
			end
		end
		if rightSchemas then
			for _, name in ipairs(rightSchemas) do
				known[name] = true
			end
		end
		for schemaName in pairs(map) do
				if not known[schemaName] then
					Log:warn("using[%s] - schema not present in this join; mapping will be ignored", tostring(schemaName))
				end
			end
		end
	ensureUsingCoverage(map, self._schemaNames, rightSchemas)
	nextBuilder._steps[#nextBuilder._steps].keySpec = { kind = "schemas", map = map }
	return nextBuilder
end

---Sets the join window/expiration policy for the current join step.
---@param joinWindow table
---@return QueryBuilder
function QueryBuilder:joinWindow(joinWindow)
	assert(type(joinWindow) == "table", "joinWindow expects a table")
	warnIfBuilt(self, "joinWindow")
	ensureStep(self)
	local nextBuilder = self:_clone()
	nextBuilder._steps[#nextBuilder._steps].joinWindow = joinWindow
	return nextBuilder
end

---Deduplicates events for a schema before downstream joins/operators.
---@param schemaName string
---@param opts table
---@return QueryBuilder
function QueryBuilder:distinct(schemaName, opts)
	assert(type(schemaName) == "string" and schemaName ~= "", "distinct expects a schema name")
	opts = opts or {}
	assert(type(opts) == "table", "distinct expects an options table")
	warnIfBuilt(self, "distinct")

	local keySelector = opts.by or opts.field
	assert(keySelector ~= nil, "distinct requires 'by' (field name or function)")
	local selectorType = type(keySelector)
	assert(
		selectorType == "string" or selectorType == "function",
		"distinct 'by' must be a string field or function"
	)

	local nextBuilder = self:_clone()
	nextBuilder._distinctSteps = nextBuilder._distinctSteps or {}
	nextBuilder._distinctSteps[#nextBuilder._distinctSteps + 1] = {
		schema = schemaName,
		keySelector = keySelector,
		window = opts.window,
		afterStepIndex = #nextBuilder._steps,
	}
	return nextBuilder
end

---Selects/renames schemas for downstream consumers.
---@param selection table
---@return QueryBuilder
function QueryBuilder:selectSchemas(selection)
	assert(type(selection) == "table", "selectSchemas expects a table")
	if self._selection ~= nil then
		Log:warn("Query.selectSchemas called multiple times; previous selection will be replaced")
	end
	warnIfBuilt(self, "selectSchemas")
	local nextBuilder = self:_clone()
	nextBuilder._selection = selection
	nextBuilder._schemaNames = deriveSchemasFromSelection(selection)
	return nextBuilder
end

---Applies a post-join WHERE-style predicate using the row-view helper.
---@param predicate fun(row:table):boolean
---@return QueryBuilder
	function QueryBuilder:where(predicate)
		assert(type(predicate) == "function", "where expects a function predicate")
		warnIfBuilt(self, "where")
		if self._wherePredicate ~= nil then
			error("Multiple where calls are not supported")
		end
		local nextBuilder = self:_clone()
		nextBuilder._wherePredicate = predicate
		return nextBuilder
	end

	---Applies a predicate to the final emission values (after joins/where/select/group/having).
	---@param predicate fun(value:any):boolean
	---@return QueryBuilder
	function QueryBuilder:finalWhere(predicate)
		assert(type(predicate) == "function", "finalWhere expects a function predicate")
		warnIfBuilt(self, "finalWhere")
		local nextBuilder = self:_clone()
		nextBuilder._finalWherePredicates = nextBuilder._finalWherePredicates or {}
		nextBuilder._finalWherePredicates[#nextBuilder._finalWherePredicates + 1] = predicate
		return nextBuilder
	end

---Returns the set of primary schemas (non-join sources) seen anywhere in the builder tree.
---@return table
function QueryBuilder:primarySchemas()
	local set = collectPrimarySchemas(self, {})
	local names = {}
	for name in pairs(set) do
		names[#names + 1] = name
	end
	table.sort(names)
	return names
end

function QueryBuilder:_build()
	if self._built then
		return self._built
	end
	Log:debug("Query.build activated; further chaining on this builder will create new queries")

	-- Explainer: build executes the declarative plan into concrete observables and merges expired side channels.
	local expiredStreams = {}
	local current = self._rootSource
	-- NOTE: use the left pipeline schemas (root) here instead of the global union so
	-- per-side buffer sizes reflect only the schemas that have actually flowed through
	-- the left side so far.
	local currentSchemas = self._rootSchemas and TableUtil.shallowArray(self._rootSchemas) or nil

	local processedJoins = 0
	current = applyDistinctSteps(current, self._distinctSteps, processedJoins, expiredStreams, self._scheduler)
	for stepIndex, step in ipairs(self._steps) do
		local rightObservable, rightExpired, rightSchemas = resolveObservable(step.source, step.sourceOpts)
		if rightExpired then
			expiredStreams[#expiredStreams + 1] = rightExpired
		end

		local keySpec = step.keySpec
		assert(keySpec and keySpec.kind == "schemas", "on(...) is required for each join step")
		local leftFilter, rightFilter
		leftFilter = filterFromMap(keySpec.map, schemaSet(currentSchemas))
		rightFilter = filterFromMap(keySpec.map, schemaSet(rightSchemas or (step.sourceSchema and { step.sourceSchema })))

		local leftRecords = flattenRecords(current, leftFilter)
		local rightRecords = flattenRecords(rightObservable, rightFilter)

		local keySelector, bufferSizes, oneShotSchemas = normalizeKeySelector(step)

		local options = normalizeJoinWindow(step, resolveDefaultJoinWindow(self), self._scheduler)
		options.joinType = step.joinType
		options.on = keySelector
		options.perKeyBufferSizeLeft = resolveBufferSize(bufferSizes, currentSchemas)
		options.perKeyBufferSizeRight = resolveBufferSize(bufferSizes, rightSchemas or (step.sourceSchema and { step.sourceSchema }))
		if oneShotSchemas then
			local function hasOneShot(schemas)
				if not schemas then
					return false
				end
				for _, name in ipairs(schemas) do
					if oneShotSchemas[name] then
						return true
					end
				end
				return false
			end
			options.distinctLeft = hasOneShot(currentSchemas)
			options.distinctRight = hasOneShot(rightSchemas or (step.sourceSchema and { step.sourceSchema }))
		end
		if self._vizHook then
			local vizOptions = self._vizHook({
				stepIndex = stepIndex,
				step = step,
				leftSchemas = currentSchemas,
				rightSchemas = rightSchemas or (step.sourceSchema and { step.sourceSchema }) or nil,
			})
			if vizOptions ~= nil then
				options.viz = vizOptions
			end
		end

		local joinObservable, expired = JoinObservable.createJoinObservable(leftRecords, rightRecords, options)
		expiredStreams[#expiredStreams + 1] = expired

		current = joinObservable:map(reattachParentSchemas)
		currentSchemas = union(currentSchemas, rightSchemas or (step.sourceSchema and { step.sourceSchema }))
		processedJoins = stepIndex
		current = applyDistinctSteps(current, self._distinctSteps, processedJoins, expiredStreams, self._scheduler)
	end

	if self._wherePredicate then
		local rowSchemas = currentSchemas and TableUtil.shallowArray(currentSchemas) or nil
		local predicate = self._wherePredicate
		current = current:map(function(value)
			return toJoinResult(value) or value
		end)
		current = current:filter(function(value)
			local result = toJoinResult(value)
			if not result then
				Log:warn("Query.where dropped emission without schema metadata")
				return false
			end
			local row = buildRowView(result, rowSchemas)
			if not row then
				return false
			end
			local ok, keep = pcall(predicate, row)
			if not ok then
				Log:warn("Query.where predicate errored - %s", tostring(keep))
				return false
			end
			local keepBool = keep and true or false
				Log:trace("[where] keep=%s ids=%s", tostring(keepBool), summarizeRowIds(row, rowSchemas))
				return keepBool
			end)
		end

	if self._selection then
		current = current:map(function(value)
			return applySelectionToResult(value, self._selection)
		end)
		for i = 1, #expiredStreams do
			expiredStreams[i] = applySelectionToExpired(expiredStreams[i], self._selection)
		end
	end

	-- Grouping (aggregate or enriched) at the tail of the pipeline.
	if not self._group then
		if self._groupWindow then
			Log:warn("Query.groupWindow configured without groupBy/groupByEnrich; configuration will be ignored")
		end
		if self._aggregates then
			Log:warn("Query.aggregates configured without groupBy/groupByEnrich; configuration will be ignored")
		end
	end
	if self._group then
		local groupOpts = self._group
		local groupWindow = self._groupWindow or {}
		validateWindowMode(groupWindow, "groupWindow")
		validateCountWindow(groupWindow, "groupWindow")
		validateTimeWindow(groupWindow, "groupWindow")
		warnUnknownKeys(groupWindow, VALID_GROUP_WINDOW_KEYS, "groupWindow")
		local aggregates = self._aggregates or {}
		if aggregates.row_count == nil then
			aggregates.row_count = true
		end
		local rowSchemas = currentSchemas and TableUtil.shallowArray(currentSchemas) or nil
		current = current:map(function(value)
			local result = toJoinResult(value)
			if not result then
				Log:warn("Grouping dropped emission without schema metadata")
				return nil
			end
			return buildRowView(result, rowSchemas)
		end):filter(function(row)
			return row ~= nil
		end)
		-- @TODO: provide a seamless helper to re-wrap grouped/enriched rows into schema-tagged streams
		-- when chaining into new queries, instead of expecting callers to hand-roll chain/wrap logic.

		local aggregateStream, enrichedStream, groupExpired = GroupByObservable.createGroupByObservable(current, {
			keySelector = groupOpts.keyFn,
			groupName = groupOpts.groupName
				or (self._schemaNames and self._schemaNames[1] and ("_groupBy:" .. self._schemaNames[1]))
				or "_groupBy",
			window = groupWindow,
			aggregates = aggregates,
			flushOnComplete = groupWindow.flushOnComplete,
			viewLabel = groupOpts.view,
		})

		if groupExpired then
			expiredStreams[#expiredStreams + 1] = groupExpired
		end

		-- Optional HAVING-style predicate over the grouped view.
		if self._havingPredicate then
			local predicate = self._havingPredicate
			if groupOpts.view == "enriched" then
				enrichedStream = enrichedStream:filter(function(row)
					local ok, keep = pcall(predicate, row)
					if not ok then
						Log:warn("Query.having (enriched) predicate errored - %s", tostring(keep))
						return false
					end
					return keep and true or false
				end)
			else
				aggregateStream = aggregateStream:filter(function(row)
					local ok, keep = pcall(predicate, row)
					if not ok then
						Log:warn("Query.having (aggregate) predicate errored - %s", tostring(keep))
						return false
					end
					return keep and true or false
				end)
			end
		end

		if groupOpts.view == "enriched" then
			current = enrichedStream
		else
			current = aggregateStream
		end
		end

		local mergedExpired = mergeObservables(expiredStreams)

		if self._finalWherePredicates and #self._finalWherePredicates >= 1 then
			for _, predicate in ipairs(self._finalWherePredicates) do
				current = current:filter(function(value)
					local ok, keep = pcall(predicate, value)
					if not ok then
						Log:warn("Query.finalWhere predicate errored - %s", tostring(keep))
						return false
					end
					return keep and true or false
				end)
			end
		end

		if self._finalTap then
			local tap = self._finalTap
			current = current:map(function(value)
				tap(value)
				return value
		end)
	end

	self._built = {
		observable = current,
		expired = mergedExpired,
		schemaNames = currentSchemas,
	}
	return self._built
end

---Subscribes to the joined observable.
---@param onNext fun(value:any)
---@param onError fun(err:any)|nil
---@param onCompleted fun()|nil
---@return rx.Subscription
function QueryBuilder:subscribe(onNext, onError, onCompleted)
	local built = self:_build()
	return built.observable:subscribe(onNext, onError, onCompleted)
end

---Returns the expired stream observable.
---@return rx.Observable
function QueryBuilder:expired()
	local built = self:_build()
	return built.expired
end

---Appends emissions into the provided table and returns a tapped observable.
---@param bucket table
---@return rx.Observable
function QueryBuilder:into(bucket)
	assert(type(bucket) == "table", "into expects a table")
	local built = self:_build()
	return rx.Observable.create(function(observer)
		local subscription
		subscription = built.observable:subscribe(function(value)
			bucket[#bucket + 1] = value
			observer:onNext(value)
		end, function(err)
			observer:onError(err)
		end, function()
			observer:onCompleted()
		end)

		return function()
			if subscription then
				subscription:unsubscribe()
			end
		end
	end)
end

local function keyDescription(step)
	local spec = step.keySpec
	if spec and spec.kind == "schemas" then
		local mapCopy = {}
		for schema, field in pairs(spec.map) do
			if type(field) == "table" then
				mapCopy[schema] = field.field
			else
				mapCopy[schema] = field
			end
		end
		return { map = mapCopy }
	end
	error("Unexpected keySpec in describe()")
end

local function joinWindowDescription(joinWindow, defaultJoinWindow)
	local source = joinWindow or defaultJoinWindow
	if not source then
		return { mode = "count", count = DEFAULT_WINDOW_COUNT }
	end
	if source.count or source.maxItems or source.mode == "count" then
		return { mode = "count", count = source.count or source.maxItems or DEFAULT_WINDOW_COUNT }
	end
	return {
		mode = "time",
		time = source.time or source.offset or 0,
		field = source.field or "sourceTime",
	}
end

local function joinWindowGcDescription(joinWindow, defaultJoinWindow)
	local source = joinWindow or defaultJoinWindow
	local description = {
		mode = "count",
		count = DEFAULT_WINDOW_COUNT,
		gcOnInsert = true,
	}
	if not source then
		return description
	end
	if source.count or source.maxItems or source.mode == "count" then
		description.mode = "count"
		description.count = source.count or source.maxItems or DEFAULT_WINDOW_COUNT
	elseif source.time or source.offset or source.mode == "time" or source.mode == "interval" then
		description.mode = "time"
		description.time = source.time or source.offset or 0
		description.field = source.field or "sourceTime"
	end
	if source.gcOnInsert ~= nil then
		description.gcOnInsert = source.gcOnInsert
	end
	if source.gcIntervalSeconds then
		description.gcIntervalSeconds = source.gcIntervalSeconds
	end
	return description
end

local function distinctWindowDescription(window)
	local source = window or {}
	local description = {
		mode = "count",
		count = DEFAULT_WINDOW_COUNT,
		gcOnInsert = true,
	}
	if source.count or source.maxItems or source.mode == "count" then
		description.mode = "count"
		description.count = source.count or source.maxItems or DEFAULT_WINDOW_COUNT
	else
		description.mode = "time"
		description.time = source.time or source.offset or 0
		description.field = source.field or "sourceTime"
	end
	if source.gcOnInsert ~= nil then
		description.gcOnInsert = source.gcOnInsert
	end
	if source.gcIntervalSeconds then
		description.gcIntervalSeconds = source.gcIntervalSeconds
	end
	return description
end

---Returns a stable description table for tests/logs.
---@return table
function QueryBuilder:describe()
	local plan = {
		from = self._rootSchemas or { "unknown" },
		joins = {},
	}
	local defaultJoinWindow = resolveDefaultJoinWindow(self)
	local planGc = joinWindowGcDescription(nil, defaultJoinWindow)
	for _, step in ipairs(self._steps) do
		plan.joins[#plan.joins + 1] = {
			type = step.joinType,
			source = step.sourceSchema or "unknown",
			key = keyDescription(step),
			joinWindow = joinWindowDescription(step.joinWindow, defaultJoinWindow),
		}
		if step.joinWindow then
			planGc = joinWindowGcDescription(step.joinWindow, defaultJoinWindow)
		end
	end
	plan.gc = planGc
	if self._distinctSteps and #self._distinctSteps > 0 then
		plan.distinct = {}
		for _, step in ipairs(self._distinctSteps) do
			plan.distinct[#plan.distinct + 1] = {
				schema = step.schema,
				by = type(step.keySelector) == "string" and step.keySelector or "function",
				afterJoin = step.afterStepIndex,
				window = distinctWindowDescription(step.window),
			}
		end
	end
	if self._selection then
		plan.select = self._selection
	end
	if self._wherePredicate then
		plan.where = true
	end
	if self._havingPredicate then
		plan.having = true
	end
	if self._group then
		local windowDesc = {
			mode = "time",
			time = 0,
			field = "sourceTime",
		}
			if self._groupWindow then
				if self._groupWindow.count then
					windowDesc = { mode = "count", count = self._groupWindow.count }
				else
					windowDesc.time = self._groupWindow.time or self._groupWindow.offset or 0
					windowDesc.field = self._groupWindow.field or "sourceTime"
				end
				if self._groupWindow.gcOnInsert ~= nil then
					windowDesc.gcOnInsert = self._groupWindow.gcOnInsert
				end
				if self._groupWindow.gcIntervalSeconds then
					windowDesc.gcIntervalSeconds = self._groupWindow.gcIntervalSeconds
			end
		end
		plan.group = {
			mode = self._group.view,
			key = "function",
			window = windowDesc,
			aggregates = self._aggregates or {},
		}
	end
	return plan
end

---Returns a stringified description (for logs).
---@return string
function QueryBuilder:describeAsString()
	local function encode(v, depth, seen)
		if depth <= 0 then
			return "..."
		end
		local t = type(v)
		if t == "table" then
			if seen[v] then
				return "<cycle>"
			end
			seen[v] = true
			local keys = {}
			for k in pairs(v) do
				keys[#keys + 1] = k
			end
			table.sort(keys, function(a, b)
				return tostring(a) < tostring(b)
			end)
			local parts = {}
			for _, k in ipairs(keys) do
				parts[#parts + 1] = string.format("%s=%s", tostring(k), encode(v[k], depth - 1, seen))
			end
			seen[v] = nil
			return "{" .. table.concat(parts, ", ") .. "}"
		elseif t == "string" then
			return string.format("%q", v)
		else
			return tostring(v)
		end
	end

	return encode(self:describe(), 4, {})
end

local Builder = {}

function Builder.newBuilder(source, opts)
	return newBuilder(source, opts)
end

function Builder.setScheduler(scheduler)
	schedulerOverride = scheduler
end

function Builder.getScheduler()
	return schedulerOverride
end

function Builder.setDefaultJoinWindow(joinWindow)
	if joinWindow ~= nil then
		assert(type(joinWindow) == "table", "setDefaultJoinWindow expects a table or nil")
	end
	defaultJoinWindowOverride = joinWindow
end

function Builder.getDefaultJoinWindow()
	return defaultJoinWindowOverride
end

function Builder.setDefaultCurrentFn(fn)
	TimeUtil.setDefaultNowFn(fn)
end

function Builder.getDefaultCurrentFn()
	return TimeUtil.defaultNowFn()
end

Builder.QueryBuilder = QueryBuilder
Builder.DEFAULT_WINDOW_COUNT = DEFAULT_WINDOW_COUNT

return Builder
-- Explainer: summarizeRowIds builds a compact string for logging WHERE decisions
-- so INFO logs stay readable without dumping whole rows.
