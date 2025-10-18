-- High-level visualization adapter: taps Query builder joins to emit normalized events
-- (sources, matches, expirations) for dynamic renderers without touching core scheduling.
local rx = require("reactivex")

local QueryVizAdapter = {}

local DEFAULT_MAX_LAYERS = 5

local function toSet(list)
	if not list then
		return {}
	end
	local set = {}
	for _, value in ipairs(list) do
		set[value] = true
	end
	return set
end

-- Simple HSV->RGB converter to generate evenly spaced schema colors.
local function hsvToRgb(h, s, v)
	local i = math.floor(h * 6)
	local f = h * 6 - i
	local p = v * (1 - s)
	local q = v * (1 - f * s)
	local t = v * (1 - (1 - f) * s)
	local mod = i % 6
	if mod == 0 then
		return v, t, p
	elseif mod == 1 then
		return q, v, p
	elseif mod == 2 then
		return p, v, t
	elseif mod == 3 then
		return p, q, v
	elseif mod == 4 then
		return t, p, v
	else
		return v, p, q
	end
end

local function rainbowPalette(names)
	local palette = {}
	local total = math.max(1, #names)
	for i, name in ipairs(names) do
		local hue = ((i - 1) % total) / total
		local r, g, b = hsvToRgb(hue, 0.7, 0.95)
		palette[name] = { r, g, b, 1 }
	end
	-- Standard outer colors for join/expired.
	palette.joined = palette.joined or { 0.2, 0.85, 0.2, 1 }
	palette.expired = palette.expired or { 0.9, 0.25, 0.25, 1 }
	return palette
end

local function clampLayer(depth, maxLayers)
	if not depth then
		return 1
	end
	if depth < 1 then
		return 1
	end
	if depth > maxLayers then
		return maxLayers
	end
	return depth
end

local function normalizeEventMapper(primarySet, maxLayers)
	local seenInner = {}
	return function(event)
		if not event then
			return nil
		end
		if event.kind == "input" and event.schema and primarySet[event.schema] then
			local id = event.id or event.key
			if id == nil then
				return nil
			end
			local token = tostring(event.schema) .. "::" .. tostring(id)
			if seenInner[token] then
				return nil
			end
			seenInner[token] = true
			return {
				type = "source",
				schema = event.schema,
				id = id,
				key = event.key,
				sourceTime = event.sourceTime,
			}
		elseif event.kind == "match" or event.kind == "unmatched" then
			return {
				type = "match",
				layer = clampLayer(event.depth, maxLayers),
				key = event.key,
				left = event.left,
				right = event.right,
				unmatched = (event.kind == "unmatched"),
			}
		elseif event.kind == "expire" then
			return {
				type = "expire",
				layer = clampLayer(event.depth, maxLayers),
				schema = event.schema,
				id = event.id,
				key = event.key,
				reason = event.reason,
			}
		end
		return nil
	end
end

local function buildDepthResolver(totalSteps, maxLayers)
	return function(stepIndex)
		-- Outermost layer is the deepest join (last step).
		local remaining = totalSteps - stepIndex
		return clampLayer((remaining or 0) + 1, maxLayers)
	end
end

local function describeJoins(plan)
	local joins = {}
	local function keyLabel(key)
		if type(key) == "string" then
			return key
		end
		if type(key) == "table" then
			if key.field then
				return key.field
			end
			if key.map then
				local parts = {}
				for schema, field in pairs(key.map) do
					parts[#parts + 1] = string.format("%s.%s", schema, tostring(field))
				end
				table.sort(parts)
				return table.concat(parts, ", ")
			end
		end
		return "id"
	end
	for _, join in ipairs(plan.joins or {}) do
		joins[#joins + 1] = {
			type = join.type,
			source = join.source,
			key = join.key,
			displayKey = keyLabel(join.key),
			window = join.window,
		}
	end
	return joins
end

---Attaches a visualization sink to a QueryBuilder and returns the wiring.
---@param queryBuilder table
---@param opts table|nil
---@return table attachment
function QueryVizAdapter.attach(queryBuilder, opts)
	assert(type(queryBuilder) == "table" and queryBuilder.withVisualizationHook, "attach expects a QueryBuilder")

	opts = opts or {}
	local maxLayers = opts.maxLayers or DEFAULT_MAX_LAYERS
	local plan = queryBuilder:describe()
	local totalSteps = #(plan.joins or {})
	local depthForStep = buildDepthResolver(totalSteps, maxLayers)

	local primaries = queryBuilder.primarySchemas and queryBuilder:primarySchemas() or (plan.from or {})
	local primarySet = toSet(primaries)
	local palette = opts.palette or rainbowPalette(primaries)

	local sink = rx.Subject.create()
	local instrumented = queryBuilder:withVisualizationHook(function(context)
		return {
			emit = function(event)
				sink:onNext(event)
			end,
			stepIndex = context.stepIndex,
			depth = depthForStep(context.stepIndex),
		}
	end)

	return {
		query = instrumented,
		events = sink,
		palette = palette,
		maxLayers = maxLayers,
		primarySchemas = primaries,
		header = {
			window = nil, -- filled by runtime snapshot
			joins = describeJoins(plan),
			from = plan.from or primaries,
			gc = plan.gc,
		},
		normalized = sink:map(normalizeEventMapper(primarySet, maxLayers)):filter(function(event)
			return event ~= nil
		end),
	}
end

return QueryVizAdapter
