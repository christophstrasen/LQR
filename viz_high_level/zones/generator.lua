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

local function ensureCircleRange(zone, warnings)
	local shape = zone.shape or "flat"
	local isCircle = shape:match("^circle%d+$")
	if not isCircle then
		return zone
	end
	if not zone.range then
		warnings[#warnings + 1] = string.format("circle zone '%s' missing range; defaulting to 20", tostring(zone.label or zone.schema))
		zone.range = 20
	end
	if zone.range and zone.range > 80 then
		warnings[#warnings + 1] = string.format("circle zone '%s' has large range (%s)", tostring(zone.label or zone.schema), tostring(zone.range))
	end
	return zone
end

local function buildProjectionOffsets(count, stride)
	local offsets = {}
	local x, y = 0, 0
	local step = 1
	local dirs = { { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0, -1 } }
	local dirIdx = 1
	offsets[#offsets + 1] = 0
	while #offsets < count do
		for _ = 1, 2 do
			local dx, dy = dirs[dirIdx][1], dirs[dirIdx][2]
			for _ = 1, step do
				if #offsets >= count then
					break
				end
				x = x + dx
				y = y + dy
				offsets[#offsets + 1] = (x) + (y * stride)
			end
			dirIdx = dirIdx % 4 + 1
		end
		step = step + 1
	end
	return offsets
end

local function applyCoverage(cells, coverage)
	local keep = math.max(1, math.floor(#cells * coverage + 0.5))
	local selected = {}
	for i = 1, math.min(keep, #cells) do
		selected[#selected + 1] = cells[i]
	end
	return selected
end

local function pickSpatialIds(zone)
	local coverage = clamp01(assertNumber(zone.coverage or zone.density or 1, "zone.coverage"))
	local weights = ShapeWeights.build(zone)
	if #weights == 0 or coverage <= 0 then
		return {}
	end
	return applyCoverage(weights, coverage)
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
---@param opts table additional options (totalPlaybackTime required, playStart optional, grid optional, stampSourceTime optional, clock optional)
---@return table events sorted by tick
---@return table summary
function Generator.generate(zones, opts)
	opts = opts or {}
	assertNumber(opts.totalPlaybackTime, "opts.totalPlaybackTime")
	local grid = opts.grid or {}
	local startId = grid.startId or 0
	local columns = grid.columns or 10
	local rows = grid.rows or 10
	local windowSize = columns * rows

	local events = {}
	local summaries = {}
	local warnings = {}
	local seen = {}
	local mappingHint = "linear"

	for idx, zone in ipairs(zones or {}) do
		zone = ensureCircleRange(zone, warnings)
		local zoneLabel = zone.label or string.format("zone_%d", idx)
		local shape = zone.shape or "flat"
		local spatial = pickSpatialIds(zone)
		local mode = zone.mode or "random"
		local tSpan = (clamp01(zone.t1 or 1) - clamp01(zone.t0 or 0)) * opts.totalPlaybackTime
		if tSpan <= 0 then
			tSpan = 1
		end
		local rate = zone.rate or (#spatial / tSpan)
		local targetCount = math.max(1, math.floor(rate * tSpan + 0.5))

		-- Build indices into spatial according to mode.
		local indices = {}
		if mode == "monotonic" then
			for i = 1, targetCount do
				indices[#indices + 1] = ((i - 1) % #spatial) + 1
			end
		else
			local order = {}
			for i = 1, #spatial do
				order[i] = i
			end
			local a, c, m = 1664525, 1013904223, 2 ^ 32
			local seed = 42
			for i = #order, 2, -1 do
				seed = (a * seed + c) % m
				local j = (seed % i) + 1
				order[i], order[j] = order[j], order[i]
			end
			for i = 1, targetCount do
				indices[#indices + 1] = order[((i - 1) % #order) + 1]
			end
		end

		local times = buildTimeSlots(zone, #indices, opts)
		local eventCount = math.min(#indices, #times)
		local shape = zone.shape or "flat"
		local needsProjection = not (shape == "continuous" or shape == "linear_in" or shape == "linear_out")
		if needsProjection then
			mappingHint = "spiral"
		end
		for i = 1, eventCount do
			local idInfo = spatial[indices[i]]
			local tick = times[i]
			local effectiveId = idInfo.id
			if idInfo.colOffset and idInfo.rowOffset then
				local baseCol = math.floor((zone.center or startId) / rows)
				local baseRow = (zone.center or startId) % rows
				local col = baseCol + idInfo.colOffset
				local row = baseRow + idInfo.rowOffset
				if col >= 0 and col < columns and row >= 0 and row < rows then
					effectiveId = startId + (col * rows) + row
				end
			end
			if effectiveId then
				local payload = buildPayload(zone, effectiveId)
				if opts.stampSourceTime and type(payload) == "table" then
					payload.RxMeta = payload.RxMeta or {}
					payload.RxMeta.sourceTime = tick
					payload.RxMeta.schema = payload.RxMeta.schema or zone.schema
					payload.RxMeta.id = payload.RxMeta.id or payload.id
					if opts.debug then
						local logger = opts.debug.logger or print
						logger(
							string.format(
								"[zone_gen] zone=%s schema=%s id=%s tick=%.3f",
								tostring(zoneLabel),
								tostring(zone.schema),
								tostring(effectiveId),
								tick
							)
						)
					end
				end
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
		mappingHint = mappingHint,
	}
end

Generator._private = {
	pickSpatialIds = pickSpatialIds,
	buildTimeSlots = buildTimeSlots,
	buildPayload = buildPayload,
}

return Generator
