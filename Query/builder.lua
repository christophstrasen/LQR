-- High-level fluent query builder (joins + selection) without manual chain wiring.
---@class QueryBuilder
---@field private _rootSource rx.Observable
---@field private _rootSchemas table|nil
---@field private _steps table
---@field private _selection table|nil
---@field private _schemaNames table|nil
---@field private _built table|nil
---@field private _defaultWindowCount number
---@field private _scheduler any
---@field private _vizHook fun(context:table):table|nil
local rx = require("reactivex")
local JoinObservable = require("JoinObservable")
local Result = require("JoinObservable.result")
local warnings = require("JoinObservable.warnings")

local warnf = warnings.warnf

local DEFAULT_WINDOW_COUNT = 1000
local schedulerOverride = nil

local QueryBuilder = {}
QueryBuilder.__index = QueryBuilder

-- Explainer: cloneArray keeps builder state immutable across chained calls.
local function cloneArray(values)
	local copy = {}
	for i = 1, #values do
		copy[i] = values[i]
	end
	return copy
end

-- Explainer: unionSchemas builds a sorted de-duped list so describe/select stay stable.
local function unionSchemas(left, right)
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
	return unionSchemas(targets)
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
	return next(set) and set or nil
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
	if next(set) then
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

local function normalizeSourceArg(source, opts)
	local schemaName
	if type(opts) == "string" then
		schemaName = opts
	elseif type(opts) == "table" then
		schemaName = opts.schema or opts.name or opts.as
	end
	return source, schemaName
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

-- Explainer: buildSelectionMap normalizes selection into schema->alias mapping for reuse.
local function buildSelectionMap(selection)
	if not selection then
		return nil
	end
	local mapping = {}
	for _, schema in ipairs(selection) do
		if type(schema) == "string" and schema ~= "" then
			mapping[schema] = schema
		end
	end
	for key, value in pairs(selection) do
		if type(key) ~= "number" and type(value) == "string" and value ~= "" then
			mapping[key] = value
		end
	end
	return next(mapping) and mapping or nil
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
				warnf("Query builder dropped emission of type %s (expected table or JoinResult)", type(value))
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

-- Explainer: selectorFromField warns on missing fields but keeps processing.
local function selectorFromField(field)
	local warned = {}
	return function(entry, _, schemaName)
		local value = entry and entry[field]
		if value == nil and schemaName and not warned[schemaName] then
			warned[schemaName] = true
			warnf("Query.onField('%s') missing for schema '%s'", field, schemaName)
		end
		return value
	end
end

-- Explainer: selectorFromSchemas drives per-schema key lookups with soft warnings for gaps.
local function selectorFromSchemas(map)
	local missingWarned = {}
	local function selector(entry, _, schemaName)
		local field = schemaName and map[schemaName]
		if not field then
			if schemaName and not missingWarned[schemaName] then
				missingWarned[schemaName] = true
				warnf("Query.onSchemas missing selector for schema '%s'", schemaName)
			end
			return nil
		end
		local value = entry and entry[field]
		if value == nil and schemaName and not missingWarned[schemaName .. "::field"] then
			missingWarned[schemaName .. "::field"] = true
			warnf("Query.onSchemas('%s') missing field '%s'", schemaName, field)
		end
		return value
	end
	return selector
end

-- Explainer: selectorFromId pulls keys from RxMeta.id and warns when absent.
local function selectorFromId()
	local warned = {}
	return function(entry, _, schemaName)
		local meta = entry and entry.RxMeta
		if meta and meta.id ~= nil then
			return meta.id
		end
		if schemaName and not warned[schemaName] then
			warned[schemaName] = true
			warnf("Query.onId() missing RxMeta.id for schema '%s'", schemaName)
		end
		return nil
	end
end

-- Explainer: normalizeKeySelector converts builder specs into the callable expected by the core join.
local function normalizeKeySelector(step)
	local spec = step.keySpec
	if not spec or spec.kind == "id" then
		return selectorFromId()
	end
	if spec.kind == "field" then
		return selectorFromField(spec.field)
	end
	if spec.kind == "schemas" then
		return selectorFromSchemas(spec.map)
	end
	return selectorFromId()
end

-- Explainer: normalizeWindow defaults to a large count window and threads scheduler into GC if available.
local function normalizeWindow(step, defaultWindowCount, scheduler)
	local window = step.window
	if not window then
		return {
			expirationWindow = {
				mode = "count",
				maxItems = defaultWindowCount,
			},
		}
	end

	if window.count then
		return {
			expirationWindow = {
				mode = "count",
				maxItems = window.count,
			},
			gcOnInsert = window.gcOnInsert,
			gcIntervalSeconds = window.gcIntervalSeconds,
			gcScheduleFn = window.gcScheduleFn,
		}
	end

	local scheduleFn = window.gcScheduleFn
	if not scheduleFn and scheduler and scheduler.schedule then
		scheduleFn = function(delaySeconds, fn)
			return scheduler:schedule(fn, delaySeconds)
		end
	end

	return {
		expirationWindow = {
			mode = "interval",
			field = window.field or "sourceTime",
			offset = window.time or window.offset or 0,
			currentFn = window.currentFn or os.time,
		},
		gcOnInsert = window.gcOnInsert,
		gcIntervalSeconds = window.gcIntervalSeconds,
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

function QueryBuilder:_clone()
	local copy = setmetatable({}, QueryBuilder)
	copy._rootSource = self._rootSource
	copy._rootSchemas = self._rootSchemas and cloneArray(self._rootSchemas) or nil
	copy._steps = {}
	for i = 1, #self._steps do
		local step = self._steps[i]
		local stepCopy = {}
		for key, value in pairs(step) do
			if key == "keySpec" and type(value) == "table" then
				local clone = {}
				for k, v in pairs(value) do
					clone[k] = v
				end
				stepCopy[key] = clone
			else
				stepCopy[key] = value
			end
		end
		copy._steps[i] = stepCopy
	end
	copy._selection = self._selection
	copy._schemaNames = self._schemaNames and cloneArray(self._schemaNames) or nil
	copy._defaultWindowCount = self._defaultWindowCount
	copy._scheduler = self._scheduler
	copy._vizHook = self._vizHook
	return copy
end

-- Explainer: ensureStep prevents configuring keys/windows before any join is staged.
local function ensureStep(builder)
	if #builder._steps == 0 then
		error("Call innerJoin/leftJoin before onField/onId/onSchemas/window")
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

-- Explainer: ensureOnSchemasCoverage enforces at least one mapping on each side when using onSchemas.
local function ensureOnSchemasCoverage(map, leftSchemas, rightSchemas)
	if leftSchemas and #leftSchemas > 0 and not hasMappingFor(map, leftSchemas) then
		error("onSchemas must map at least one left-side schema")
	end
	if rightSchemas and #rightSchemas > 0 and not hasMappingFor(map, rightSchemas) then
		error("onSchemas must map at least one right-side schema")
	end
end

local function deriveSchemasFromSelection(selection)
	local targets = selectionTargets(selection)
	return targets
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

local function resolveObservable(source)
	if getmetatable(source) == QueryBuilder then
		local built = source:_build()
		return built.observable, built.expired, source._schemaNames
	end
	return source, nil, nil
end

---Internal helper to build a new QueryBuilder from a source.
---@param source rx.Observable
---@param opts table|string|nil
---@return QueryBuilder
local function newBuilder(source, opts)
	assert(source and source.subscribe, "Query.from expects an observable")
	local observable, schemaName = normalizeSourceArg(source, opts)
	local builder = setmetatable({}, QueryBuilder)
	builder._rootSource = observable
	builder._rootSchemas = schemaName and { schemaName } or nil
	builder._schemaNames = builder._rootSchemas and cloneArray(builder._rootSchemas) or nil
	builder._steps = {}
	builder._defaultWindowCount = DEFAULT_WINDOW_COUNT
	builder._scheduler = schedulerOverride
	builder._vizHook = nil
	return builder
end

function QueryBuilder:_addStep(joinType, source, opts)
	local observable, schemaName = normalizeSourceArg(source, opts)
	local nextBuilder = self:_clone()
	nextBuilder._steps[#nextBuilder._steps + 1] = {
		joinType = joinType,
		source = observable,
		sourceSchema = schemaName,
	}
	if schemaName then
		nextBuilder._schemaNames = unionSchemas(nextBuilder._schemaNames, { schemaName })
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

---Attaches a visualization hook (optional, no-op in normal runs).
---@param vizHook fun(context:table):table|nil
---@return QueryBuilder
function QueryBuilder:withVisualizationHook(vizHook)
	if vizHook ~= nil then
		assert(type(vizHook) == "function", "withVisualizationHook expects a function or nil")
	end
	local nextBuilder = self:_clone()
	nextBuilder._vizHook = vizHook
	return nextBuilder
end

---Configures the key selector to use a single field for all schemas.
---@param field string
---@return QueryBuilder
function QueryBuilder:onField(field)
	assert(type(field) == "string" and field ~= "", "onField expects a non-empty string")
	ensureStep(self)
	local nextBuilder = self:_clone()
	nextBuilder._steps[#nextBuilder._steps].keySpec = { kind = "field", field = field }
	return nextBuilder
end

---Configures the key selector to use RxMeta.id per schema.
---@return QueryBuilder
function QueryBuilder:onId()
	ensureStep(self)
	local nextBuilder = self:_clone()
	nextBuilder._steps[#nextBuilder._steps].keySpec = { kind = "id" }
	return nextBuilder
end

---Configures explicit schema->field mappings for join keys.
---@param map table
---@return QueryBuilder
function QueryBuilder:onSchemas(map)
	assert(type(map) == "table", "onSchemas expects a table")
	ensureStep(self)
	local hasEntries = next(map) ~= nil
	assert(hasEntries, "onSchemas expects at least one mapping")
	local nextBuilder = self:_clone()
	local step = nextBuilder._steps[#nextBuilder._steps]
	local rightSchemas = step and step.sourceSchema and { step.sourceSchema } or nil
	if step and getmetatable(step.source) == QueryBuilder then
		rightSchemas = step.source._schemaNames or rightSchemas
	end
	ensureOnSchemasCoverage(map, self._schemaNames, rightSchemas)
	nextBuilder._steps[#nextBuilder._steps].keySpec = { kind = "schemas", map = map }
	return nextBuilder
end

---Sets the window/expiration policy for the current join step.
---@param window table
---@return QueryBuilder
function QueryBuilder:window(window)
	assert(type(window) == "table", "window expects a table")
	ensureStep(self)
	local nextBuilder = self:_clone()
	nextBuilder._steps[#nextBuilder._steps].window = window
	return nextBuilder
end

---Selects/renames schemas for downstream consumers.
---@param selection table
---@return QueryBuilder
function QueryBuilder:selectSchemas(selection)
	assert(type(selection) == "table", "selectSchemas expects a table")
	local nextBuilder = self:_clone()
	nextBuilder._selection = selection
	nextBuilder._schemaNames = deriveSchemasFromSelection(selection)
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

	-- Explainer: build executes the declarative plan into concrete observables and merges expired side channels.
	local expiredStreams = {}
	local current = self._rootSource
	local currentSchemas = self._schemaNames and cloneArray(self._schemaNames) or nil

	for stepIndex, step in ipairs(self._steps) do
		local rightObservable, rightExpired, rightSchemas = resolveObservable(step.source)
		if rightExpired then
			expiredStreams[#expiredStreams + 1] = rightExpired
		end

		local keySpec = step.keySpec
		local leftFilter, rightFilter
		if keySpec and keySpec.kind == "schemas" then
			leftFilter = filterFromMap(keySpec.map, schemaSet(currentSchemas))
			rightFilter = filterFromMap(keySpec.map, schemaSet(rightSchemas or (step.sourceSchema and { step.sourceSchema })))
		end

		local leftRecords = flattenRecords(current, leftFilter)
		local rightRecords = flattenRecords(rightObservable, rightFilter)

		local options = normalizeWindow(step, self._defaultWindowCount, self._scheduler)
		options.joinType = step.joinType
		options.on = normalizeKeySelector(step)
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
		currentSchemas = unionSchemas(currentSchemas, rightSchemas or (step.sourceSchema and { step.sourceSchema }))
	end

	if self._selection then
		current = current:map(function(value)
			return applySelectionToResult(value, self._selection)
		end)
		for i = 1, #expiredStreams do
			expiredStreams[i] = applySelectionToExpired(expiredStreams[i], self._selection)
		end
	end

	local mergedExpired = mergeObservables(expiredStreams)
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
	if not spec or spec.kind == "id" then
		return "RxMeta.id"
	end
	if spec.kind == "field" then
		return { field = spec.field }
	end
	if spec.kind == "schemas" then
		local mapCopy = {}
		for schema, field in pairs(spec.map) do
			mapCopy[schema] = field
		end
		return { map = mapCopy }
	end
	return "RxMeta.id"
end

local function windowDescription(window, defaultWindowCount)
	if not window then
		return { mode = "count", count = defaultWindowCount }
	end
	if window.count then
		return { mode = "count", count = window.count }
	end
	return {
		mode = "time",
		time = window.time or window.offset or 0,
		field = window.field or "sourceTime",
	}
end

---Returns a stable description table for tests/logs.
---@return table
function QueryBuilder:describe()
	local plan = {
		from = self._rootSchemas or { "unknown" },
		joins = {},
	}
	for _, step in ipairs(self._steps) do
		plan.joins[#plan.joins + 1] = {
			type = step.joinType,
			source = step.sourceSchema or "unknown",
			key = keyDescription(step),
			window = windowDescription(step.window, self._defaultWindowCount),
		}
	end
	if self._selection then
		plan.select = self._selection
	end
	return plan
end

---Returns a stringified description (for logs).
---@return string
function QueryBuilder:describeAsString()
	local ok, encoded = pcall(require, "dkjson")
	if ok and encoded and encoded.encode then
		return encoded.encode(self:describe(), { indent = true })
	end
	return tostring(self:describe())
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

Builder.QueryBuilder = QueryBuilder
Builder.DEFAULT_WINDOW_COUNT = DEFAULT_WINDOW_COUNT

return Builder
