-- Provides a shallow merge so demos can add their overrides on top of an empty base.
local M = {}
local TableUtil = require("LQR/util/table")

function M.merge(overrides)
	return TableUtil.shallowCopy(overrides)
end

return M
