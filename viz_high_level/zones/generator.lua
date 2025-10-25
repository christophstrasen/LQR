local ShapeWeights = require("viz_high_level.zones.shape_weights")

local Generator = {}

local RATE_SHAPES = {
	constant = function(_count, idx)
		return 1
	end,
	linear_up = function(count, idx)
		if count <= 1 then
			return 1
		end
		return idx / count
	end,
	linear_down = function(count, idx)
		if count <= 1 then
			return 1
		end
		return (count - idx + 1) / count
	end,
	bell = function(count, idx)
		if count <= 1 then
			return 1
		end
		local t = (idx - 1) / (count - 1)
		return 0.5 - 0.5 * math.cos((math.pi * 2) * t)
	end,
}

local function clamp01(v)
	if v < 0 then
		return 0
	elseif v > 1 then
		return 1
	end
	return v
end

local function assertNumber(value, label)
	if type(value) ~= "number" then
		error(string.format("%s must be a number", tostring(label)))
	end
	return value
end

local function buildPayload(zone, id)
	if zone.payloadForId then
		return zone.payloadForId(id)
	end
	local idField = zone.idField or "id"
	return { [idField] = id }
end

local function pickSpatialIds(zone)
	local density = clamp01(assertNumber(zone.density or 1, "zone.density"))
	local weights = ShapeWeights.build(zone)
	if #weights == 0 or density <= 0 then
		return {}
	end

	table.sort(weights, function(a, b)
		if a.weight == b.weight then
			return a.id < b.id
		end
		return a.weight > b.weight
	end)

	local count = math.max(1, math.floor(#weights * density + 0.5))
	local selected = {}
	for i = 1, math.min(count, #weights) do
		selected[#selected + 1] = weights[i]
	end

	table.sort(selected, function(a, b)
		return a.id < b.id
	end)

	return selected
end

local function buildTimeSlots(zone, eventCount, opts)
	if eventCount <= 0 then
		return {}
	end
	local t0 = clamp01(assertNumber(zone.t0 or 0, "zone.t0"))
	local t1 = clamp01(assertNumber(zone.t1 or 1, "zone.t1"))
	local span = math.max(0, t1 - t0)
	if span <= 0 then
		return {}
	end

	local rateShapeName = zone.rate_shape or "constant"
	local rateShape = RATE_SHAPES[rateShapeName]
	if not rateShape then
		error(string.format("Unknown rate_shape '%s'", tostring(rateShapeName)))
	end

	local weights = {}
	for i = 1, eventCount do
		weights[i] = clamp01(rateShape(eventCount, i))
	end

	local totalWeight = 0
	for _, weight in ipairs(weights) do
		totalWeight = totalWeight + weight
	end
	if totalWeight <= 0 then
		return {}
	end

	local times = {}
	local acc = 0
	for i = 1, eventCount do
		acc = acc + weights[i]
		local tNorm = acc / totalWeight
		local t = t0 + (span * tNorm)
		local tick = (opts.playStart or 0) + (t * opts.totalPlaybackTime)
		times[#times + 1] = tick
	end

	return times
end

local function summarizeSchema(summaries, schema, event, zoneLabel)
	local summary = summaries[schema]
	if not summary then
		summary = {
			count = 0,
			minId = nil,
			maxId = nil,
			firstTick = nil,
			lastTick = nil,
			perZone = {},
		}
		summaries[schema] = summary
	end

	summary.count = summary.count + 1
	local id = event.payload and event.payload.id
	if id then
		if not summary.minId or id < summary.minId then
			summary.minId = id
		end
		if not summary.maxId or id > summary.maxId then
			summary.maxId = id
		end
	end
	local tick = event.tick
	if tick then
		if not summary.firstTick or tick < summary.firstTick then
			summary.firstTick = tick
		end
		if not summary.lastTick or tick > summary.lastTick then
			summary.lastTick = tick
		end
	end
	if zoneLabel then
		summary.perZone[zoneLabel] = (summary.perZone[zoneLabel] or 0) + 1
	end
end

local function warnDuplicates(seen, event, warnings)
	local id = event.payload and event.payload.id
	if not id then
		return
	end
	local key = table.concat({ event.schema, id, event.tick or 0 }, ":")
	if seen[key] then
		warnings[#warnings + 1] = string.format("duplicate schema/id/tick %s", key)
	end
	seen[key] = true
end

---Generate deterministic events from zone specs.
---@param zones table[] list of zone specs
---@param opts table additional options (totalPlaybackTime required, playStart optional)
---@return table events sorted by tick
---@return table summary
function Generator.generate(zones, opts)
	opts = opts or {}
	assertNumber(opts.totalPlaybackTime, "opts.totalPlaybackTime")

	local events = {}
	local summaries = {}
	local warnings = {}
	local seen = {}

	for idx, zone in ipairs(zones or {}) do
		local zoneLabel = zone.label or string.format("zone_%d", idx)
		local spatial = pickSpatialIds(zone)
		local times = buildTimeSlots(zone, #spatial, opts)

		local eventCount = math.min(#spatial, #times)
		for i = 1, eventCount do
			local idInfo = spatial[i]
			local tick = times[i]
			local payload = buildPayload(zone, idInfo.id)
			local event = {
				tick = tick,
				schema = zone.schema,
				payload = payload,
				zone = zoneLabel,
			}
			warnDuplicates(seen, event, warnings)
			events[#events + 1] = event
			summarizeSchema(summaries, zone.schema, event, zoneLabel)
		end
	end

	table.sort(events, function(a, b)
		if a.tick == b.tick then
			if a.schema == b.schema then
				return tostring(a.zone) < tostring(b.zone)
			end
			return tostring(a.schema) < tostring(b.schema)
		end
		return (a.tick or 0) < (b.tick or 0)
	end)

	return events, {
		total = #events,
		schemas = summaries,
		warnings = warnings,
	}
end

Generator._private = {
	pickSpatialIds = pickSpatialIds,
	buildTimeSlots = buildTimeSlots,
	buildPayload = buildPayload,
}

return Generator
