local Time = {}

---Return a monotonic-ish clock (prefers Love timer when available).
---@return number
function Time.nowSeconds()
	if love and love.timer and love.timer.getTime then
		return love.timer.getTime()
	end
local function safe_clock()
	if os and type(os.clock) == "function" then
		return os.clock()
	end
	-- Fallback to zero when no clock is available (e.g., PZ runtime).
	return 0
end

return safe_clock()
end

return Time
