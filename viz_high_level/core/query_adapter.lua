-- High-level visualization adapter: taps Query builder joins to emit normalized events
-- (sources, matches, expirations) for dynamic renderers without touching core scheduling.
local rx = require("reactivex")
local warnings = require("JoinObservable.warnings")
local warnf = warnings and warnings.warnf or function() end

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

local RESERVED_HUES = { 0.0, 1 / 3 }
local MIN_HUE_DISTANCE = 0.08

local function normalizeRange(startHue, endHue)
	if startHue < 0 then
		startHue = startHue + 1
	end
	if endHue < 0 then
		endHue = endHue + 1
	end
	if startHue > 1 then
		startHue = startHue - 1
	end
	if endHue > 1 then
		endHue = endHue - 1
	end
	return startHue, endHue
end

local function subtractRange(allowed, removeStart, removeEnd)
	local newAllowed = {}
	for _, seg in ipairs(allowed) do
		local segStart, segEnd = seg[1], seg[2]
		if removeEnd <= segStart or removeStart >= segEnd then
			newAllowed[#newAllowed + 1] = seg
		else
			if removeStart > segStart then
				newAllowed[#newAllowed + 1] = { segStart, removeStart }
			end
			if removeEnd < segEnd then
				newAllowed[#newAllowed + 1] = { removeEnd, segEnd }
			end
		end
	end
	return newAllowed
end

local function buildAllowedRanges()
	local allowed = { { 0, 1 } }
	for _, reserved in ipairs(RESERVED_HUES) do
		local startHue = reserved - MIN_HUE_DISTANCE
		local endHue = reserved + MIN_HUE_DISTANCE
		startHue, endHue = normalizeRange(startHue, endHue)
		if startHue < endHue then
			allowed = subtractRange(allowed, startHue, endHue)
		else
			allowed = subtractRange(allowed, startHue, 1)
			allowed = subtractRange(allowed, 0, endHue)
		end
	end
	if #allowed == 0 then
		allowed = { { 0, 1 } }
	end
	return allowed
end

local function hueAtOffset(allowed, offset)
	for _, seg in ipairs(allowed) do
		local segLen = seg[2] - seg[1]
		if offset <= segLen then
			return seg[1] + offset
		end
		offset = offset - segLen
	end
	return allowed[#allowed][2]
end

local function rainbowPalette(names)
	local palette = {}
	local total = math.max(1, #names)
	local allowed = buildAllowedRanges()
	local totalRange = 0
	for _, seg in ipairs(allowed) do
		totalRange = totalRange + (seg[2] - seg[1])
	end
	if totalRange <= 0 then
		allowed = { { 0, 1 } }
		totalRange = 1
	end
	for i, name in ipairs(names) do
		local unit = ((i - 0.5) / total) % 1
		local offset = unit * totalRange
		local hue = hueAtOffset(allowed, offset)
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

local function tokenFor(schema, id)
	if not schema or id == nil then
		return nil
	end
	return tostring(schema) .. "::" .. tostring(id)
end

local function normalizeEventMapper(primarySet, maxLayers)
	-- Explainer: we remember primary source ids so repeated cache inserts do not spam visualization rows.
	-- Tokens are released once a row expires or is flushed as unmatched, so future inserts show up as updates.
	local seenInner = {}

	local function markSeen(schema, id)
		local token = tokenFor(schema, id)
		if not token then
			return false
		end
		if seenInner[token] then
			return true
		end
		seenInner[token] = true
		return false
	end

	local function release(schema, id)
		local token = tokenFor(schema, id)
		if token then
			seenInner[token] = nil
		end
	end

	return function(event)
		if not event then
			return nil
		end
		if event.kind == "input" and event.schema and primarySet[event.schema] then
			local id = event.id or event.key
			if id == nil then
				return nil
			end
			if markSeen(event.schema, id) then
				return nil
			end
			return {
				type = "source",
				schema = event.schema,
				id = id,
				key = event.key,
				sourceTime = event.sourceTime,
				record = event.entry,
			}
		elseif event.kind == "match" or event.kind == "unmatched" then
			if event.kind == "unmatched" then
				release(event.schema, event.id)
			end
			return {
				type = "joinresult",
				kind = event.kind,
				layer = clampLayer(event.depth, maxLayers),
				key = event.key,
				id = event.id,
				left = event.left,
				right = event.right,
				schema = event.schema,
				side = event.side,
				entry = event.entry,
				unmatched = (event.kind == "unmatched"),
			}
		elseif event.kind == "expire" then
			release(event.schema, event.id)
			return {
				type = "expire",
				layer = clampLayer(event.depth, maxLayers),
				schema = event.schema,
				id = event.id,
				key = event.key,
				entry = event.entry,
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
			projectionFields = join.projectionFields,
		}
	end
	return joins
end

local function buildProjectionMap(plan)
	local map = {}
	local projectionDomainSchema, projectionField

	-- Use first join's left key as projection domain.
	local firstJoin = plan.joins and plan.joins[1]
	if firstJoin and firstJoin.key and firstJoin.key.map then
		for schema, field in pairs(firstJoin.key.map) do
			if firstJoin.source ~= schema then
				-- left side
				projectionDomainSchema = schema
				projectionField = field
				map[schema] = field
				break
			end
		end
		-- Fallback: self-join or single entry map.
		if not projectionDomainSchema then
			for schema, field in pairs(firstJoin.key.map) do
				projectionDomainSchema = schema
				projectionField = field
				map[schema] = field
				break
			end
		end
	end

	if projectionDomainSchema and projectionField then
		local function extendWith(join)
			if not join.key or not join.key.map then
				return
			end
			-- Only propagate when a schema appears with its known projection field.
			local hasProjectableOnProjectionField = false
			for schema, field in pairs(join.key.map) do
				if map[schema] and map[schema] == field then
					hasProjectableOnProjectionField = true
					break
				end
			end
			if not hasProjectableOnProjectionField then
				return
			end
			for schema, field in pairs(join.key.map) do
				if not map[schema] then
					map[schema] = field
				end
			end
		end

		-- Seed with the first join.
		extendWith(firstJoin)
		-- Propagate to downstream joins.
		for _, join in ipairs(plan.joins or {}) do
			extendWith(join)
		end
	end

	return map, projectionDomainSchema, projectionField
end

local function planHasSchemaMapping(plan)
	for _, join in ipairs(plan.joins or {}) do
		if join.key and join.key.map then
			return true
		end
	end
	return false
end

local function enrichProjection(event, projection, projectionFields)
	if not event or not projection then
		return event
	end
	local domain = projection.domain
	local fields = projectionFields or {}

	local function resolveKey(schema, payload)
		if not schema or not payload then
			return nil
		end
		local field = fields[schema]
		if field and type(payload) == "table" then
			return payload[field] or payload.id or payload.key
		end
		return nil
	end

	if event.type == "source" then
		event.projectionDomain = domain
		event.projectionKey = resolveKey(event.schema, event.record)
		event.projectable = event.projectionKey ~= nil
	elseif event.type == "expire" then
		event.projectionDomain = domain
		local fallback = (event.schema and event.key) or nil
		event.projectionKey = resolveKey(event.schema, event.entry) or fallback
		event.projectable = event.projectionKey ~= nil
	else
		event.projectionDomain = domain
		local key = nil
		-- Prefer root schema if present on either side.
		if event.left and fields[event.left.schema] then
			key = resolveKey(event.left.schema, event.left.entry) or key
		end
		if event.right and fields[event.right.schema] and not key then
			key = resolveKey(event.right.schema, event.right.entry)
		end
		-- Fallback to event.key if it matches any projectable schema.
		if not key then
			if event.left and fields[event.left.schema] then
				key = event.key
			elseif event.right and fields[event.right.schema] then
				key = event.key
			elseif event.schema and fields[event.schema] then
				key = resolveKey(event.schema, event.entry) or event.key
			end
		end
		event.projectionKey = key
		event.projectable = key ~= nil
	end
	return event
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
	if not planHasSchemaMapping(plan) then
		warnf("[QueryVizAdapter] Visualization requires Query:onSchemas mappings to derive projection domains")
	end

	local primaries = queryBuilder.primarySchemas and queryBuilder:primarySchemas() or (plan.from or {})
	local primarySet = toSet(primaries)
	local palette = opts.palette or rainbowPalette(primaries)
	local projectionFields, projectionDomainSchema, projectionField = buildProjectionMap(plan)

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
			projection = {
				domain = projectionDomainSchema or (plan.from and plan.from[1]) or primaries[1],
				field = projectionField,
				fields = projectionFields,
			},
		},
		normalized = sink:map(normalizeEventMapper(primarySet, maxLayers))
			:map(function(event)
				return enrichProjection(event, {
					domain = projectionDomainSchema or (plan.from and plan.from[1]) or primaries[1],
				}, projectionFields)
				end)
				:filter(function(event)
					return event ~= nil
				end),
	}
end

return QueryVizAdapter
