local Color = {}

---Return a new RGBA table with missing channels defaulted.
---@param color table|nil
---@param fallback table|nil
function Color.clone(color, fallback)
	local src = color or fallback or { 0, 0, 0, 1 }
	return { src[1] or 0, src[2] or 0, src[3] or 0, src[4] or 1 }
end

---Convert HSV (0-1 ranges) to RGB (0-1 ranges).
---@param h number
---@param s number
---@param v number
---@return number, number, number
function Color.hsvToRgb(h, s, v)
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

return Color
