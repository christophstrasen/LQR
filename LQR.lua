-- Shim so hosts without folder-based init loading can `require("LQR")`.
-- Falls back to LQR/init.lua and emits a friendly hint on failure.
local function loadLQR()
	local ok, result = pcall(require, "LQR.init")
	if not ok then
		local msg = string.format(
			"LQR: failed to load LQR.init (%s). Ensure the LQR/ folder is present and on package.path.",
			tostring(result)
		)
		print(msg)
		return nil
	end
	return result
end

return loadLQR()
