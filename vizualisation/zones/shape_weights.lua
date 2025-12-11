local Math = require("LQR/util/math")

local ShapeWeights = {}

local TWO_PI = math.pi * 2
local FIXED_SEED = 42

local clamp01 = Math.clamp01

local function linProgress(idx, count)
	if count <= 1 then
		return 0
	end
	return (idx - 1) / (count - 1)
end

local function resolveRange(zone)
	local hr = zone.range
	if not hr then
		error("zone.range (id span around center) is required")
	end
	return hr
end

-- Deterministic shuffle using a fixed seed.
local function lcgShuffle(list)
	local a = 1664525
	local c = 1013904223
	local m = 2 ^ 32
	local seed = FIXED_SEED
	for i = #list, 2, -1 do
		seed = (a * seed + c) % m
		local j = (seed % i) + 1
		list[i], list[j] = list[j], list[i]
	end
	return list
end

local function spiralOffsets(count, span)
	local offsets = {}
	local step = 0
	local idx = 1
	offsets[idx] = 0
	idx = idx + 1
	while idx <= count do
		step = step + 1
		for _, sign in ipairs({ 1, -1 }) do
			if idx > count then
				break
			end
			local offset = sign * math.min(step, span)
			offsets[idx] = offset
			idx = idx + 1
		end
	end
	return offsets
end

local function buildLine(center, halfRange, weightFn)
	local weights = {}
	local total = halfRange * 2 + 1
	for i = 0, total - 1 do
		local offset = i - halfRange
		local id = center + offset
		local t = linProgress(i + 1, total)
		local weight = clamp01(weightFn(t))
		weights[#weights + 1] = { id = id, weight = weight }
	end
	return weights
end

local function buildCircle(spec)
	local size = spec.size or 10
	if size < 1 then
		return {}
	end
	local radius = size / 2
	local weights = {}
	for row = 1, size do
		for col = 1, size do
			local dx = col - (radius + 0.5)
			local dy = row - (radius + 0.5)
			local dist = math.sqrt(dx * dx + dy * dy)
			local weight = 0
			if dist <= radius then
				weight = clamp01(1 - (dist / radius))
			end
			local linearIndex = (row - 1) * size + (col - 1)
			weights[#weights + 1] = {
				offset = linearIndex,
				weight = weight,
				size = size,
			}
		end
	end
	table.sort(weights, function(a, b)
		if a.weight == b.weight then
			return a.offset < b.offset
		end
		return a.weight > b.weight
	end)

	local mapped = {}
	local maxOffset = (size * size) - 1
	local span = spec.range or maxOffset
	if span < 1 then
		span = maxOffset
	end

	local offsets = spiralOffsets(#weights, span)

	for idx, cell in ipairs(weights) do
		local idOffset = offsets[idx] or 0
		mapped[#mapped + 1] = {
			id = (spec.center or 0) + idOffset,
			weight = clamp01(cell.weight),
		}
	end
	return mapped
end

---Return a list of { id, weight } pairs describing the spatial shape.
---@param zone table
---@return table
local function sortedIds(weights)
	local ids = {}
	for _, w in ipairs(weights) do
		ids[#ids + 1] = w.id
	end
	table.sort(ids)
	return ids
end

local function buildMonotonic(center, range)
	return buildLine(center, range, function()
		return 1
	end)
end

local function buildFlatField(center, range)
	local weights = buildLine(center, range, function()
		return 1
	end)
	local ids = sortedIds(weights)
	lcgShuffle(ids)
	local mapped = {}
	for _, id in ipairs(ids) do
		mapped[#mapped + 1] = { id = id, weight = 1 }
	end
	return mapped
end

local function buildBell(center, range)
	local weights = buildLine(center, range, function()
		return 1
	end)
	local ids = sortedIds(weights)
	local mid = (ids[1] + ids[#ids]) / 2
	table.sort(ids, function(a, b)
		local da = math.abs(a - mid)
		local db = math.abs(b - mid)
		if da == db then
			return a < b
		end
		return da < db
	end)
	local mapped = {}
	for _, id in ipairs(ids) do
		mapped[#mapped + 1] = { id = id, weight = 1 }
	end
	return mapped
end

local function buildCircleOrdered(center, range, size)
	local weights = buildCircle({
		center = center,
		range = range,
		size = size,
	})
	local offsets = spiralOffsets(#weights, range)
	local mapped = {}
	for idx, offset in ipairs(offsets) do
		mapped[#mapped + 1] = { id = center + offset, weight = 1 }
	end
	return mapped
end

local function buildLinearIn(center, range)
	local weights = buildLine(center, range, function(t)
		return t
	end)
	table.sort(weights, function(a, b)
		if a.weight == b.weight then
			return a.id < b.id
		end
		return a.weight > b.weight
	end)
	return weights
end

local function buildLinearOut(center, range)
	local weights = buildLine(center, range, function(t)
		return 1 - t
	end)
	table.sort(weights, function(a, b)
		if a.weight == b.weight then
			return a.id < b.id
		end
		return a.weight > b.weight
	end)
	return weights
end

local function buildCircleMask(size)
	local radius = size / 2
	local centerOffset = math.floor((size - 1) / 2)
	local cells = {}
	for row = 0, size - 1 do
		for col = 0, size - 1 do
			local dx = col - (radius - 0.5)
			local dy = row - (radius - 0.5)
			local dist = math.sqrt(dx * dx + dy * dy)
			if dist <= radius then
				cells[#cells + 1] = {
					colOffset = col - centerOffset,
					rowOffset = row - centerOffset,
					weight = clamp01(1 - (dist / radius)),
				}
			end
		end
	end
	table.sort(cells, function(a, b)
		if a.weight == b.weight then
			if a.rowOffset == b.rowOffset then
				return a.colOffset < b.colOffset
			end
			return a.rowOffset < b.rowOffset
		end
		return a.weight > b.weight
	end)
	return cells
end

function ShapeWeights.build(zone)
	local center = assert(zone.center, "zone center is required")
	local range = resolveRange(zone)
	local shape = zone.shape or "flat"

	if shape == "continuous" then
		return buildMonotonic(center, range)
	elseif shape == "flatField" then
		return buildFlatField(center, range)
	elseif shape == "bell" then
		return buildBell(center, range)
	elseif shape == "linear_in" then
		return buildLinearIn(center, range)
	elseif shape == "linear_out" then
		return buildLinearOut(center, range)
	end

	local size = shape:match("^circle(%d+)$")
	if size then
		local radiusOverride = tonumber(zone.radius)
		local maskSize
		if radiusOverride then
			-- Interpret radius as actual radius in grid cells; masks operate on side-length.
			maskSize = math.max(1, math.floor(radiusOverride * 2))
		end
		maskSize = maskSize or tonumber(size)
		return buildCircleMask(maskSize)
	end

	error(string.format("Unknown shape '%s'", tostring(shape)))
end

ShapeWeights._private = {
	buildLine = buildLine,
	buildCircle = buildCircle,
	linProgress = linProgress,
	clamp01 = clamp01,
	resolveRange = resolveRange,
	spiralOffsets = spiralOffsets,
	lcgShuffle = lcgShuffle,
}

return ShapeWeights
