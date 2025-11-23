local Color = {}

---Return a new RGBA table with missing channels defaulted.
---@param color table|nil
---@param fallback table|nil
function Color.clone(color, fallback)
	local src = color or fallback or { 0, 0, 0, 1 }
	return { src[1] or 0, src[2] or 0, src[3] or 0, src[4] or 1 }
end

return Color
