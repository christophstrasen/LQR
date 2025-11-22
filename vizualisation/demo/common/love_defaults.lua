-- Shared helper to build demo loveDefaults without changing behavior.
-- Provides a shallow merge so demos can add their overrides on top of an empty base.
local M = {}

local function cloneTable(src)
	if not src then
		return {}
	end
	local dst = {}
	for k, v in pairs(src) do
		dst[k] = v
	end
	return dst
end

function M.merge(overrides)
	local merged = cloneTable({})
	for k, v in pairs(overrides or {}) do
		merged[k] = v
	end
	return merged
end

return M
