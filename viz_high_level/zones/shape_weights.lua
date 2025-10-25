local ShapeWeights = {}

local TWO_PI = math.pi * 2

local function linProgress(idx, count)
	if count <= 1 then
		return 0
	end
	return (idx - 1) / (count - 1)
end

local function clamp01(v)
	if v < 0 then
		return 0
	elseif v > 1 then
		return 1
	end
	return v
end

local function buildLine(center, radius, weightFn)
	local weights = {}
	local total = radius * 2 + 1
	for i = 0, total - 1 do
		local offset = i - radius
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
	local minOffset = 0
	local maxOffset = (size * size) - 1
	local span = spec.radius or maxOffset
	if span < 1 then
		span = maxOffset
	end
	for _, cell in ipairs(weights) do
		local t = 0
		if maxOffset > minOffset then
			t = (cell.offset - minOffset) / (maxOffset - minOffset)
		end
		local idOffset = math.floor(-span + (t * 2 * span) + 0.5)
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
function ShapeWeights.build(zone)
	local center = assert(zone.center, "zone center is required")
	local radius = assert(zone.radius, "zone radius is required")
	local shape = zone.shape or "flat"

	if shape == "flat" then
		return buildLine(center, radius, function()
			return 1
		end)
	elseif shape == "linear_in" then
		return buildLine(center, radius, function(t)
			return t
		end)
	elseif shape == "linear_out" then
		return buildLine(center, radius, function(t)
			return 1 - t
		end)
	elseif shape == "bell" then
		return buildLine(center, radius, function(t)
			return 0.5 - 0.5 * math.cos(TWO_PI * clamp01(t))
		end)
	end

	local size = shape:match("^circle(%d+)$")
	if size then
		return buildCircle({
			center = center,
			radius = radius,
			size = tonumber(size),
		})
	end

	error(string.format("Unknown shape '%s'", tostring(shape)))
end

ShapeWeights._private = {
	buildLine = buildLine,
	buildCircle = buildCircle,
	linProgress = linProgress,
	clamp01 = clamp01,
}

return ShapeWeights
