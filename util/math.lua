local Math = {}

---Clamp a number into [min, max].
---@param value number
---@param min number
---@param max number
function Math.clamp(value, min, max)
	if value < min then
		return min
	end
	if value > max then
		return max
	end
	return value
end

---Clamp a number into [0, 1].
---@param value number
function Math.clamp01(value)
	return Math.clamp(value, 0, 1)
end

return Math
