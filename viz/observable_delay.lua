local rx = require("reactivex")
local TimeUtils = require("viz.time_utils")

local DEBUG_TIMING = os.getenv("VIZ_DEBUG_TIMING") == "1"

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
		local function ensureSourceTime(value)
			if type(value) ~= "table" then
			return
		end
		local meta = value.RxMeta
		if type(meta) ~= "table" then
			return
		end
	if meta.sourceTime == nil then
		meta.sourceTime = TimeUtils.nowEpochSeconds()
	end
end

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
					if value then
						ensureSourceTime(value)
 						if DEBUG_TIMING and value.RxMeta then
 							local schema = value.RxMeta.schema or "?"
 							local id = value.RxMeta.id or value.id or "?"
 							local ts = value.RxMeta.sourceTime or -1
 							print(string.format("[timing] emit schema=%s id=%s ts=%.3f", schema, tostring(id), ts))
 						end
					end
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
