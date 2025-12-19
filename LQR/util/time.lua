-- time.lua -- shared default clock override for windowing (join/group/distinct).
local Time = {}

local defaultNowFn = nil

local function fallbackNowFn()
	if os and type(os.time) == "function" then
		return os.time
	end
	return function()
		return 0
	end
end

---Returns the currently configured default currentFn (or an os.time-based fallback).
---@return fun():number
function Time.defaultNowFn()
	return defaultNowFn or fallbackNowFn()
end

---Overrides the default currentFn used for time/interval windows.
---Pass nil to reset to the os.time-based fallback.
---@param fn fun():number|nil
function Time.setDefaultNowFn(fn)
	if fn ~= nil then
		assert(type(fn) == "function", "setDefaultNowFn expects a function or nil")
	end
	defaultNowFn = fn
end

return Time

