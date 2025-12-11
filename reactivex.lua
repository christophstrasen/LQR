-- Shim so hosts without folder-based init loading can `require("reactivex")`.
-- Falls back to reactivex/init.lua and emits a friendly hint on failure.
local function loadReactiveX()
	local ok, result = pcall(require, "reactivex.init")
	if not ok then
		local msg = string.format(
			"reactivex: failed to load reactivex.init (%s). Ensure the reactivex/ folder is present and on package.path.",
			tostring(result)
		)
		print(msg)
		return nil
	end
	return result
end

return loadReactiveX()
