-- High-level visualization adapter: taps Query builder joins to emit normalized events
-- (sources, matches, expirations) for dynamic renderers without touching core scheduling.
local rx = require("reactivex")
local JoinLog = require("log").withTag("join")
local VizLog = require("log").withTag("viz-hi")
local Result = require("JoinObservable.result")

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

local function tryResolveKey(schemaName, entry, projectionFields)
	if not schemaName or not entry then
		return nil
	end
	local fields = projectionFields and projectionFields[schemaName]
	local field
	if type(fields) == "table" then
		field = fields.field or fields[1]
	else
		field = fields
	end
	if field and entry[field] ~= nil then
		return entry[field]
	end
	return entry.id or (entry.RxMeta and (entry.RxMeta.joinKey or entry.RxMeta.id))
end

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
	palette.final = palette.final or { 0.2, 0.85, 0.2, 1 }
	-- Preserve legacy palette.joined consumers by aliasing to final when unset.
	palette.joined = palette.joined or palette.final
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

local function shouldLogEvents(opts)
	if opts and opts.logEvents ~= nil then
		return not not opts.logEvents
	end
	-- Env override: VIZ_LOG_EVENTS=0 disables, anything else is enabled by default.
	if os.getenv("VIZ_LOG_EVENTS") == "0" then
		return false
	end
	return true
end

local function logEvent(event, logEvents)
	if not logEvents then
		return
	end
	if not event then
		return
	end
	-- Use explicit strings so callers see why/what is drawn.
	if event.type == "source" then
		VizLog:info(
			"[draw source] schema=%s id=%s key=%s sourceTime=%s",
			tostring(event.schema),
			tostring(event.id),
			tostring(event.key),
			tostring(event.sourceTime)
		)
		VizLog:debug("[draw source] schema=%s id=%s entry=%s", tostring(event.schema), tostring(event.id), tostring(event.record))
	elseif event.type == "joinresult" then
		if event.kind == "match" then
			local leftId = event.left and event.left.id or event.left and event.left.metaId or nil
			local rightId = event.right and event.right.id or event.right and event.right.metaId or nil
			VizLog:info(
				"[draw join] kind=match key=%s leftSchema=%s leftId=%s rightSchema=%s rightId=%s layer=%s",
				tostring(event.key),
				event.left and tostring(event.left.schema) or "",
				tostring(leftId),
				event.right and tostring(event.right.schema) or "",
				tostring(rightId),
				tostring(event.layer)
			)
			VizLog:debug("[draw join] key=%s left=%s right=%s", tostring(event.key), tostring(event.left), tostring(event.right))
		else
			VizLog:info(
				"[draw join] kind=%s schema=%s id=%s key=%s side=%s layer=%s",
				tostring(event.kind),
				tostring(event.schema),
				tostring(event.id),
				tostring(event.key),
				tostring(event.side),
				tostring(event.layer)
			)
			VizLog:debug("[draw join] kind=%s entry=%s", tostring(event.kind), tostring(event.entry))
		end
	elseif event.type == "expire" then
		VizLog:info(
			"[draw expire] schema=%s id=%s key=%s reason=%s layer=%s",
			tostring(event.schema),
			tostring(event.id),
			tostring(event.key),
			tostring(event.reason),
			tostring(event.layer)
		)
		VizLog:debug("[draw expire] entry=%s", tostring(event.entry))
	end
end

local function normalizeEventMapper(primarySet, maxLayers)
	-- NOTE: we previously deduped repeat source emissions per schema/id (using seenInner)
	-- to avoid redraw spam. That hides meaningful re-emits for the same id, so we now
	-- let all inputs through. If we need the filter again, reintroduce the seenInner
	-- tracking that lived here and skipped repeat inputs until expire/unmatched.
	return function(event)
		if not event then
			return nil
		end
		if event.kind == "input" and event.schema and primarySet[event.schema] then
			local id = event.id or event.key
			if id == nil then
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
	elseif event.kind == "final" then
		return {
			type = "joinresult",
			kind = "final",
			layer = clampLayer(event.depth or maxLayers, maxLayers),
			key = event.key,
			id = event.id,
			schema = event.schema,
			entry = event.entry,
			result = event.result,
			unmatched = false,
		}
	elseif event.kind == "expire" then
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

local function schemasForKey(key)
	if type(key) == "table" and key.map then
		local names = {}
		for schema in pairs(key.map) do
			names[#names + 1] = schema
		end
		table.sort(names)
		return names
	end
	return {}
end

local function describeJoins(plan, depthResolver)
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
		local layer = depthResolver and depthResolver(#joins + 1) or nil
		joins[#joins + 1] = {
			type = join.type,
			source = join.source,
			key = join.key,
			displayKey = keyLabel(join.key),
			joinWindow = join.joinWindow,
			projectionFields = join.projectionFields,
			schemas = schemasForKey(join.key),
			layer = layer,
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

local function finalEventFromResult(result, projectionDomainSchema, projectionField, projectionFields, depth)
	if not result or getmetatable(result) ~= Result then
		return nil
	end
	local domain = projectionDomainSchema or (result:schemaNames()[1])
	if not domain then
		return nil
	end
	local record = result:get(domain)
	local key = tryResolveKey(domain, record, projectionFields) or (record and projectionField and record[projectionField])
	local id = record and (record.id or (record.RxMeta and record.RxMeta.id))
	return {
		kind = "final",
		schema = domain,
		id = id,
		key = key,
		entry = record,
		result = result,
		depth = depth,
	}
end

local function planHasSchemaMapping(plan)
	for _, join in ipairs(plan.joins or {}) do
		if join.key and join.key.map then
			return true
		end
	end
	return false
end

local function tryResolveKey(schemaName, entry, projectionFields)
	if not schemaName or not entry then
		return nil
	end
	local fields = projectionFields or {}
	local field = fields[schemaName]
	if field and type(entry) == "table" then
		if type(field) == "table" then
			field = field.field or field[1]
		end
		if field and entry[field] ~= nil then
			return entry[field]
		end
	end
	if type(entry) == "table" then
		return entry.id or (entry.RxMeta and (entry.RxMeta.joinKey or entry.RxMeta.id))
	end
	return nil
end

local function enrichProjection(event, projection, projectionFields)
	if not event or not projection then
		return event
	end
	local domain = projection.domain
	local fields = projectionFields or {}

	if event.type == "source" then
		event.projectionDomain = domain
		event.projectionKey = tryResolveKey(event.schema, event.record, fields)
		event.projectable = event.projectionKey ~= nil
	elseif event.type == "expire" then
		event.projectionDomain = domain
		local fallback = (event.schema and event.key) or nil
		event.projectionKey = tryResolveKey(event.schema, event.entry, fields) or fallback
		event.projectable = event.projectionKey ~= nil
	else
		event.projectionDomain = domain
		local key = nil
		-- Prefer root schema if present on either side.
		if event.left and fields[event.left.schema] then
			key = tryResolveKey(event.left.schema, event.left.entry, fields) or key
		end
		if event.right and fields[event.right.schema] and not key then
			key = tryResolveKey(event.right.schema, event.right.entry, fields)
		end
		-- Fallback to event.key if it matches any projectable schema.
		if not key then
			if event.left and fields[event.left.schema] then
				key = event.key
			elseif event.right and fields[event.right.schema] then
				key = event.key
			elseif event.schema and fields[event.schema] then
				key = tryResolveKey(event.schema, event.entry, fields) or event.key
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
	local logEvents = shouldLogEvents(opts)
	local maxLayers = opts.maxLayers or DEFAULT_MAX_LAYERS
	local plan = queryBuilder:describe()
	local totalSteps = #(plan.joins or {})
	local depthForStep = buildDepthResolver(totalSteps, maxLayers)
	if not planHasSchemaMapping(plan) then
		JoinLog:warn("[QueryVizAdapter] Visualization requires Query:onSchemas mappings to derive projection domains")
	end

	local primaries = queryBuilder.primarySchemas and queryBuilder:primarySchemas() or (plan.from or {})
	local primarySet = toSet(primaries)
	local palette = opts.palette or rainbowPalette(primaries)
	local projectionFields, projectionDomainSchema, projectionField = buildProjectionMap(plan)
	local joins = describeJoins(plan, depthForStep)
	local joinColors = {}
	for _, join in ipairs(joins) do
		local layer = join.layer
		if layer then
			local colors = {}
			for _, schema in ipairs(join.schemas or {}) do
				local c = palette[schema]
				if c then
					colors[#colors + 1] = c
				end
			end
			if #colors > 0 then
				local sumR, sumG, sumB, sumA = 0, 0, 0, 0
				for _, c in ipairs(colors) do
					sumR = sumR + (c[1] or 0)
					sumG = sumG + (c[2] or 0)
					sumB = sumB + (c[3] or 0)
					sumA = sumA + (c[4] or 1)
				end
				local count = #colors
				joinColors[layer] = { sumR / count, sumG / count, sumB / count, sumA / count }
			end
		end
	end

	local sink = rx.Subject.create()
	local finalTapStream = rx.Subject.create()
	local instrumented = queryBuilder
		:withVisualizationHook(function(context)
			return {
				emit = function(event)
					sink:onNext(event)
				end,
				stepIndex = context.stepIndex,
				depth = depthForStep(context.stepIndex),
			}
		end)
		:withFinalTap(function(value)
			finalTapStream:onNext(value)
		end)

	local finalDepth = depthForStep(totalSteps) or maxLayers
	local normalizedFinal = finalTapStream:map(function(result)
		return finalEventFromResult(result, projectionDomainSchema, projectionField, projectionFields, finalDepth)
	end)

	local baseStream = sink:filter(function(event)
		-- Drop pre-WHERE join result events when we have a final tap; keep sources/expire.
		return not (event and (event.kind == "match" or event.kind == "unmatched"))
	end)

	return {
		query = instrumented,
		events = sink,
		palette = palette,
		maxLayers = maxLayers,
		primarySchemas = primaries,
		header = {
			window = nil, -- filled by runtime snapshot
			joins = joins,
			from = plan.from or primaries,
			gc = plan.gc,
			joinColors = joinColors,
			projection = {
				domain = projectionDomainSchema or (plan.from and plan.from[1]) or primaries[1],
				field = projectionField,
				fields = projectionFields,
			},
		},
		normalized = baseStream:merge(normalizedFinal)
			:map(normalizeEventMapper(primarySet, maxLayers))
			:map(function(event)
				return enrichProjection(event, {
					domain = projectionDomainSchema or (plan.from and plan.from[1]) or primaries[1],
				}, projectionFields)
			end)
			:map(function(event)
				logEvent(event, logEvents)
				return event
			end)
			:filter(function(event)
				return event ~= nil
			end),
	}
end

return QueryVizAdapter
