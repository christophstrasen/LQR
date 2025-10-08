local rx = require("reactivex")

local TimeUtils = {}

function TimeUtils.nowEpochSeconds()
	local seconds = os.time()
	local scheduler = rx.scheduler.get()
	if scheduler and scheduler.currentTime then
		local fractional = scheduler.currentTime % 1
		return seconds + fractional
	end
	return seconds
end

return TimeUtils
