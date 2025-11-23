local Table = {}

---Shallow copy of an array-like table, preserving order.
---@param values table|nil
---@return table
function Table.shallowArray(values)
	if not values then
		return {}
	end
	local copy = {}
	for i = 1, #values do
		copy[i] = values[i]
	end
	return copy
end

---Shallow copy of a map-like table.
---@param src table|nil
---@return table
function Table.shallowCopy(src)
	if not src then
		return {}
	end
	local dst = {}
	for k, v in pairs(src) do
		dst[k] = v
	end
	return dst
end

---Convert an array of values into a set-like lookup table.
---@param list table|nil
---@return table
function Table.toSet(list)
	local set = {}
	for _, value in ipairs(list or {}) do
		if value ~= nil then
			set[value] = true
		end
	end
	return set
end

return Table
