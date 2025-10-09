local rx = require("reactivex")
local TimeUtils = require("viz.time_utils")

local DEBUG_TIMING = os.getenv("VIZ_DEBUG_TIMING") == "1"

local RandomDelay = {}

local function resolveDelayBounds(opts)
	opts = opts or {}
	local minDelay = math.max(0, opts.minDelay or 0)
	local maxDelay = math.max(minDelay, opts.maxDelay or minDelay)
	return minDelay, maxDelay
end

local function sampleDelay(minDelay, maxDelay)
	if maxDelay <= minDelay then
		return minDelay
	end
	return minDelay + math.random() * (maxDelay - minDelay)
end

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

function RandomDelay.withDelay(source, opts)
	opts = opts or {}
	local delayMode = (opts.delayMode or opts.mode or "jittered"):lower()
	local minDelay, maxDelay = resolveDelayBounds(opts)
	local jitterRange = math.max(0, maxDelay - minDelay)

	return rx.Observable.create(function(observer)
		local cancelled = false
		local subscription
		local scheduler = rx.scheduler
		local latestDue
		local delayedTimeline

		local function currentTime()
			local currentScheduler = scheduler.get()
			return (currentScheduler and currentScheduler.currentTime) or 0
		end

		latestDue = currentTime()
		delayedTimeline = latestDue

		local function computeDue(useDelay)
			local now = currentTime()

			if not useDelay then
				local due = math.max(latestDue, now)
				latestDue = due
				return due
			end

			delayedTimeline = math.max(delayedTimeline, now)
			local baseDelay = sampleDelay(minDelay, maxDelay)
			delayedTimeline = delayedTimeline + baseDelay
			local due = delayedTimeline

			if delayMode ~= "ordered" and jitterRange > 0 then
				local jitter = (math.random() - 0.5) * jitterRange
				due = due + jitter
				if due <= now then
					due = now + math.max(jitterRange * 0.1, 1e-3)
				end
			end

			if due < now then
				due = now
			end

			if due > latestDue then
				latestDue = due
			end

			return due
		end

		local function scheduleCall(callback, value, useDelay)
			local now = currentTime()
			local due = computeDue(useDelay)
			local relativeDelay = math.max(0, due - now)

			scheduler.schedule(function()
				if cancelled then
					return
				end

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
