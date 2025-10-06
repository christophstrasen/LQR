local rx = require("reactivex")

local RandomDelay = {}

local function computeDelay(opts)
	local minDelay = math.max(0, opts.minDelay or 0)
	local maxDelay = math.max(minDelay, opts.maxDelay or minDelay)
	if maxDelay <= minDelay then
		return minDelay
	end
	return minDelay + math.random() * (maxDelay - minDelay)
end

function RandomDelay.withDelay(source, opts)
	opts = opts or {}
	return rx.Observable.create(function(observer)
		local cancelled = false
		local subscription
		local nextDue = rx.scheduler.get().currentTime or 0

		local function scheduleCall(callback, value, useDelay)
			local now = rx.scheduler.get().currentTime or 0
			if useDelay == false then
				if nextDue < now then
					nextDue = now
				end
			else
				if nextDue < now then
					nextDue = now
				end
				nextDue = nextDue + computeDelay(opts)
			end
			local relativeDelay = math.max(0, nextDue - now)
			rx.scheduler.schedule(function()
				if not cancelled then
					callback(value)
				end
			end, relativeDelay)
		end

		subscription = source:subscribe(
			function(value)
				scheduleCall(function(v)
					observer:onNext(v)
				end, value, true)
			end,
			function(err)
				scheduleCall(function(e)
					observer:onError(e)
				end, err, false)
			end,
			function()
				scheduleCall(function()
					observer:onCompleted()
				end, nil, false)
			end
		)

		return function()
			cancelled = true
			if subscription and subscription.unsubscribe then
				subscription:unsubscribe()
			end
		end
	end)
end

return RandomDelay
