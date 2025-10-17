local rx = require("reactivex")
local ScenarioLoader = require("viz_low_level.scenario_loader")
local Observables = require("viz_low_level.observables")
local VizConfig = ScenarioLoader.getRecipe(Observables)
local windowConfig = VizConfig.window or {}
local PreRender = {}

math.randomseed(os.time())

local DEFAULT_FADE_DURATION = windowConfig.fadeSeconds or 10 -- seconds to decay alpha from 100 to 0
local DEBUG_BASE = os.getenv("DEBUG") == "1"
local DEBUG_SUBS = os.getenv("DEBUG_SUBS") == "1" or DEBUG_BASE
local function collectPalette(config)
	local palette = {}
	if not config then
		return palette
	end
	local window = config.window or {}
	local layers = window.layers or {}
	for _, layer in pairs(layers) do
		for _, stream in ipairs(layer.streams or {}) do
			if stream.name and stream.color then
				palette[stream.name] = stream.color
			end
		end
	end
	return palette
end

local DEFAULT_COLORS = collectPalette(VizConfig)
if not next(DEFAULT_COLORS) then
	DEFAULT_COLORS.default = { 0.2, 0.2, 0.2, 1 }
end
local DEFAULT_GRID = windowConfig.grid or {}

local function globalStartOffset()
	local grid = windowConfig.grid
	if grid and grid.startOffset ~= nil then
		return grid.startOffset
	end
	if windowConfig.startOffset ~= nil then
		return windowConfig.startOffset
	end
	if windowConfig.minId ~= nil then
		return windowConfig.minId
	end
	return nil
end

local function cloneTable(source)
	if not source then
		return {}
	end
	local copy = {}
	for key, value in pairs(source) do
		copy[key] = value
	end
	return copy
end

local function cloneColor(color)
	return { color[1], color[2], color[3], color[4] or 1 }
end

local function clampAlpha(alpha)
	if alpha == nil then
		return 0
	end
	if alpha < 0 then
		return 0
	end
	if alpha > 100 then
		return 100
	end
	return alpha
end

local PreRenderState = {}
PreRenderState.__index = PreRenderState

function PreRenderState.new(opts)
	opts = opts or {}
	local state = setmetatable({
		columns = opts.columns or 32,
		rows = opts.rows or 32,
		maxEntries = (opts.columns or 32) * (opts.rows or 32),
		palette = opts.palette or DEFAULT_COLORS,
		fadePerSecond = opts.fadePerSecond
			or (opts.fadeDuration and (100 / opts.fadeDuration))
			or (100 / DEFAULT_FADE_DURATION),
		idMapper = opts.idMapper,
		order = {},
		entries = {},
		subscriptions = {},
		counters = {},
	}, PreRenderState)
	return state
end

function PreRenderState:decayEntry(entry, amount)
	local decay = amount or 0
	if decay <= 0 then
		return
	end
	entry.alpha = clampAlpha((entry.alpha or 100) - decay)
end

function PreRenderState:decayAll(amount)
	for _, entry in pairs(self.entries) do
		self:decayEntry(entry, amount)
	end
end

function PreRenderState:advance(dt)
	if not dt or dt <= 0 then
		return
	end
	local amount = self.fadePerSecond * dt
	if amount <= 0 then
		return
	end
	self:decayAll(amount)
end

local function mixColors(entry, templateColor)
	-- Explainer: even if the existing entry is at full intensity, we want to show overlap,
	-- so cap the weight to allow a 50/50 mix on back-to-back events.
	local existingWeight = clampAlpha(entry.alpha or 0) / 100
	if existingWeight >= 1 then
		existingWeight = 0.5
	end
	local newWeight = 1 - existingWeight
	if existingWeight <= 0 then
		return cloneColor(templateColor)
	end
	return {
		entry.color[1] * existingWeight + templateColor[1] * newWeight,
		entry.color[2] * existingWeight + templateColor[2] * newWeight,
		entry.color[3] * existingWeight + templateColor[3] * newWeight,
		1,
	}
end

function PreRenderState:ingest(id, paletteKey, info)
	if not id then
		return nil
	end
	local template = self.palette[paletteKey]
	if not template then
		return nil
	end
	self.counters[paletteKey] = (self.counters[paletteKey] or 0) + 1

	local entry = self.entries[id]
	if not entry then
		entry = {
			id = id,
			color = cloneColor(template),
			alpha = 100,
			meta = info,
			sources = { paletteKey },
		}
		self.entries[id] = entry
		table.insert(self.order, id)
	else
		entry.color = mixColors(entry, template)
		entry.alpha = 100
		entry.sources[#entry.sources + 1] = paletteKey
		if info ~= nil then
			entry.meta = info
		end
	end
	return entry
end

function PreRenderState:getCount(paletteKey)
	return self.counters[paletteKey] or 0
end

function PreRenderState:indexToCoordinate(index)
	local col = ((index - 1) % self.columns) + 1
	local row = math.floor((index - 1) / self.columns) + 1
	return col, row
end

function PreRenderState:coordinateForEntry(entry, index)
	if self.idMapper then
		local col, row = self.idMapper(entry.id, self, index)
		if col and row then
			return col, row
		end
	end
	return self:indexToCoordinate(index)
end

function PreRenderState:forEachInOrder(callback)
	for index, id in ipairs(self.order) do
		local entry = self.entries[id]
		if entry then
			local col, row = self:coordinateForEntry(entry, index)
			if row <= self.rows and col <= self.columns then
				local continue = callback(entry, col, row, index)
				if continue == false then
					break
				end
			end
		end
	end
end

function PreRenderState:attachSource(opts)
	assert(opts and opts.observable, "opts.observable is required")
	assert(opts.paletteKey, "opts.paletteKey is required")
	assert(type(opts.extract) == "function", "opts.extract must be a function")

	if DEBUG_SUBS then
		print(string.format("[viz-sub] subscribe paletteKey=%s layer=%s", opts.paletteKey, tostring(opts.layer or "?")))
	end
	local subscription = opts.observable:subscribe(function(value)
		local id, info = opts.extract(value)
		if id then
			self:ingest(id, opts.paletteKey, info)
		end
	end)
		self.subscriptions[#self.subscriptions + 1] = subscription
		local function unsubscribe()
			if DEBUG_SUBS then
				print(string.format("[viz-sub] unsubscribe paletteKey=%s layer=%s", opts.paletteKey, tostring(opts.layer or "?")))
			end
			if subscription and subscription.unsubscribe then
				subscription:unsubscribe()
			end
		end
	return { unsubscribe = unsubscribe }
end

function PreRenderState:teardown()
	for _, subscription in ipairs(self.subscriptions) do
		if subscription and subscription.unsubscribe then
			subscription:unsubscribe()
		end
	end
	self.subscriptions = {}
end

PreRender.State = PreRenderState
PreRender.DEFAULT_COLORS = DEFAULT_COLORS
PreRender.DEFAULT_FADE_DURATION = DEFAULT_FADE_DURATION

function PreRender.rasterIdMapper(minId, wrap)
	minId = minId or 0
	return function(id, state)
		if type(id) ~= "number" then
			return nil, nil
		end
		local offset = math.max(0, math.floor(id - minId))
		local col = (offset % state.columns) + 1
		local row = math.floor(offset / state.columns) + 1
		if wrap and row > state.rows then
			row = ((row - 1) % state.rows) + 1
		end
		return col, row
	end
end

local function readPath(container, segments)
	if not container then
		return nil
	end
	local value = container
	for index = 1, #segments do
		if type(value) ~= "table" then
			return nil
		end
		value = value[segments[index]]
		if value == nil then
			return nil
		end
	end
	return value
end

local function ensureTable(value)
	if type(value) == "table" then
		return value
	end
	if value == nil then
		return {}
	end
	return { value = value }
end

local function resolveSchemaSource(value, context, schema)
	if not schema then
		return context or value
	end
	local function attempt(container)
		if type(container) ~= "table" then
			return nil
		end
		if container.schemas and container.schemas[schema] ~= nil then
			return container.schemas[schema]
		end
		if container[schema] ~= nil then
			return container[schema]
		end
		local getter = container.get
		if type(getter) == "function" then
			local ok, result = pcall(getter, container, schema)
			if ok and result ~= nil then
				return result
			end
		end
		return nil
	end
	return attempt(context) or attempt(value) or context or value
end

local function buildResolver(definition, fallback)
	definition = definition or fallback
	if definition == nil then
		return function()
			return nil
		end
	end
	local defType = type(definition)
	if defType == "function" then
		return function(value, context)
			return definition(value, context)
		end
	elseif defType == "string" then
		local path = {}
		for segment in definition:gmatch("[^%.]+") do
			path[#path + 1] = segment
		end
		return function(value, context)
			local ctx = ensureTable(context)
			local result = readPath(ctx, path)
			if result ~= nil then
				return result
			end
			return readPath(ensureTable(value), path)
		end
	elseif defType == "table" then
		if definition.constant ~= nil then
			return function()
				return definition.constant
			end
		elseif definition.field ~= nil then
			return buildResolver(definition.field)
		end
	elseif definition == true then
		return function(value, context)
			if value ~= nil then
				return value
			end
			return context
		end
	end
	return function()
		return nil
	end
end

local function cloneOptions(opts)
	return cloneTable(opts)
end

local function resolveMapperConfig(value)
	if type(value) == "function" then
		return value
	end
	if type(value) == "table" then
		local mapperType = value.type or "raster"
		if mapperType == "raster" or value.minId or value.wrap ~= nil then
			local minId = value.minId or windowConfig.minId or 0
			local wrap = value.wrap
			if wrap == nil then
				wrap = true
			end
			return PreRender.rasterIdMapper(minId, wrap)
		end
	end
	return nil
end

local function resolveDefaultIdMapper(opts)
	opts = opts or {}
	if opts.idMapper then
		if type(opts.idMapper) == "function" then
			return opts.idMapper
		end
		local mapper = resolveMapperConfig(opts.idMapper)
		if mapper then
			return mapper
		end
	end
	local mapper = resolveMapperConfig(windowConfig.idMapper)
	if mapper then
		return mapper
	end
	local startOffset = globalStartOffset()
	return PreRender.rasterIdMapper(startOffset or 0, true)
end

local function buildLayerStates(baseOpts)
	local layerStates = {}
	local layersConfig = (VizConfig.window and VizConfig.window.layers) or {}
	local defaultIdMapper = baseOpts.idMapper
	for name, layerConfig in pairs(layersConfig) do
		local stateOpts = cloneOptions(baseOpts)
		stateOpts.columns = layerConfig.columns or stateOpts.columns
		stateOpts.rows = layerConfig.rows or stateOpts.rows
		stateOpts.fadeDuration = layerConfig.fadeDurationSeconds or layerConfig.fadeSeconds or stateOpts.fadeDuration
		local startOffset = layerConfig.startOffset
		if startOffset == nil then
			startOffset = globalStartOffset()
		end
		local explicitMapper = resolveMapperConfig(layerConfig.idMapper) or defaultIdMapper
		if layerConfig.idMapper or windowConfig.idMapper then
			stateOpts.idMapper = explicitMapper
		elseif startOffset ~= nil then
			stateOpts.idMapper = PreRender.rasterIdMapper(startOffset, true)
		else
			stateOpts.idMapper = explicitMapper
		end
		stateOpts.palette = baseOpts.palette
		layerStates[name] = PreRenderState.new(stateOpts)
	end
	local requiredLayers = VizConfig.layerOrder or (windowConfig.layerOrder) or { "inner", "outer" }
	for _, name in ipairs(requiredLayers) do
		if not layerStates[name] then
			local fallbackOpts = cloneOptions(baseOpts)
			fallbackOpts.idMapper = defaultIdMapper
			layerStates[name] = PreRenderState.new(fallbackOpts)
		end
	end
	return layerStates
end

local function buildHoverResolvers(hoverFields)
	local resolvers = {}
	if not hoverFields then
		return resolvers
	end
	for _, entry in ipairs(hoverFields) do
		local key
		local definition
		local schema
		if type(entry) == "string" then
			key = entry
			definition = entry
		elseif type(entry) == "table" then
			key = entry.key or entry.name or entry.field or entry[1]
			schema = entry.schema
			if entry.fn then
				definition = entry.fn
			elseif entry.field then
				definition = entry.field
			elseif entry.constant ~= nil then
				definition = { constant = entry.constant }
			elseif entry.record then
				definition = true
			elseif entry.value ~= nil then
				definition = entry.value
			elseif schema then
				definition = true
			else
				definition = entry
			end
		end
		if key and definition then
			resolvers[#resolvers + 1] = {
				key = key,
				schema = schema,
				resolver = buildResolver(definition),
			}
		end
	end
	return resolvers
end

local function buildFieldResolvers(map)
	local resolvers = {}
	if not map then
		return resolvers
	end
	for key, definition in pairs(map) do
		local schema
		local resolvedDef = definition
		if type(definition) == "table" and definition.schema then
			schema = definition.schema
			local copy = cloneTable(definition)
			copy.schema = nil
			if copy.fn then
				resolvedDef = copy.fn
			elseif copy.field then
				resolvedDef = copy.field
			elseif copy.constant ~= nil then
				resolvedDef = { constant = copy.constant }
			elseif copy.record then
				resolvedDef = true
			elseif copy.value ~= nil then
				resolvedDef = copy.value
			else
				resolvedDef = true
			end
		end
		if resolvedDef == nil then
			resolvedDef = true
		end
		resolvers[key] = {
			schema = schema,
			resolver = buildResolver(resolvedDef),
		}
	end
	return resolvers
end

local function buildTrackResolvers(descriptor)
	local trackers = descriptor.tracks or descriptor.trackers
	if type(trackers) == "table" and #trackers > 0 then
		local resolvers = {}
		for _, track in ipairs(trackers) do
			if track then
				local schema = track.schema
				local definition
				if type(track) == "table" then
					if track.field ~= nil then
						definition = track.field
					elseif track.selector ~= nil then
						definition = track.selector
					elseif track.constant ~= nil then
						definition = { constant = track.constant }
					elseif track.value ~= nil then
						definition = { constant = track.value }
					else
						local copy = cloneTable(track)
						copy.schema = nil
						if next(copy) ~= nil then
							definition = copy
						end
					end
				else
					definition = track
				end
				resolvers[#resolvers + 1] = {
					schema = schema,
					resolver = buildResolver(definition or "id"),
				}
			end
		end
		if #resolvers > 0 then
			return resolvers
		end
	end
	return {
		{
			schema = descriptor.track_schema or descriptor.trackSchema,
			resolver = buildResolver(descriptor.track_field or descriptor.trackField or descriptor.track or "id"),
		},
	}
end

local function buildStreamExtractor(descriptor)
	local transform = descriptor.transform
	local trackResolvers = buildTrackResolvers(descriptor)
	local hoverResolvers = buildHoverResolvers(descriptor.hoverFields)
	local metaResolvers = buildFieldResolvers(descriptor.meta)

	return function(value)
		local context = value
		if transform then
			local transformed = transform(value)
			if transformed ~= nil then
				context = transformed
			end
		end
		local id
		for _, tracker in ipairs(trackResolvers) do
			local idSource = resolveSchemaSource(value, context, tracker.schema)
			id = tracker.resolver(idSource, context)
			if id ~= nil then
				break
			end
		end
		if id == nil then
			return nil
		end
		local meta = { id = id }
		for key, resolverInfo in pairs(metaResolvers) do
			local source = resolveSchemaSource(value, context, resolverInfo.schema)
			meta[key] = resolverInfo.resolver(source, context)
		end
		if value and value.RxMeta then
			meta.sourceTime = value.RxMeta.sourceTime
		end
		if #hoverResolvers > 0 then
			local hover = {}
			for _, entry in ipairs(hoverResolvers) do
				local source = resolveSchemaSource(value, context, entry.schema)
				hover[entry.key] = entry.resolver(source, context)
			end
			meta.hover = hover
		end
		return id, meta
	end
end

local function attachObservable(layerStates, spec, observable)
	if not observable or not spec or not spec.paletteKey then
		return
	end
	local layerName = spec.layer or "inner"
	local state = layerStates[layerName]
	if not state then
		return
	end
	local extractor = spec.extract or buildStreamExtractor(spec)
	state:attachSource({
		observable = observable,
		paletteKey = spec.paletteKey,
		extract = extractor,
	})
	if spec.decayAfter then
		state:decayAll(spec.decayAfter)
	end
end

local function attachConfiguredStreams(layerStates)
	local layers = windowConfig.layers or {}
	for layerName, layer in pairs(layers) do
		for _, descriptor in ipairs(layer.streams or {}) do
			if descriptor.observable then
				attachObservable(layerStates, {
					layer = layerName,
					paletteKey = descriptor.name or descriptor.paletteKey or "default",
					extract = descriptor.extract or buildStreamExtractor(descriptor),
					decayAfter = descriptor.decayAfter,
				}, descriptor.observable)
			end
		end
	end
end

local function buildConfiguredStates(opts)
	opts = cloneOptions(opts or {})
	local grid = windowConfig.grid or {}
	opts.columns = opts.columns or grid.columns or 32
	opts.rows = opts.rows or grid.rows or 32
	opts.palette = opts.palette or cloneOptions(DEFAULT_COLORS)
	opts.fadeDuration = opts.fadeDuration or windowConfig.fadeSeconds or DEFAULT_FADE_DURATION
	opts.idMapper = resolveDefaultIdMapper(opts)
	local layerStates = buildLayerStates(opts)
	attachConfiguredStreams(layerStates)
	return layerStates
end

function PreRender.buildConfiguredStates(opts)
	return buildConfiguredStates(opts)
end

function PreRender.buildDemoStates(opts)
	local states = buildConfiguredStates(opts)
	return states.inner, states.outer, states
end

function PreRender.buildDemoState(opts)
	local states = PreRender.buildConfiguredStates(opts)
	return states.inner
end

return PreRender
