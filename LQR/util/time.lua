local Time = {}

---Return a monotonic-ish clock (prefers Love timer when available).
---@return number
function Time.nowSeconds()
	if love and love.timer and love.timer.getTime then
		return love.timer.getTime()
	end
	return os.clock()
end

return Time
