-- Highlights per-side interval windows so you can see asymmetric retention in action.
-- Handy when each source has different freshness guarantees and needs its own TTL.

-- Expected console: match for order 101, right-only output when order 202 expires quickly, and a late left-only expiration for order 303.
require("bootstrap")
local io = require("io")

local rx = require("reactivex")
local JoinObservable = require("JoinObservable")
local Schema = require("JoinObservable.schema")

local now = 0
local function currentTime()
	return now
end

local function emit(subject, payload)
	now = payload.ts
	subject:onNext(payload)
end

-- Subjects act as both observers and observables, letting us push data manually while others subscribe.
-- We use them here so we can emit timestamped records at controlled times to exercise the TTL logic.
local leftSource = rx.Subject.create()
local rightSource = rx.Subject.create()
local left = Schema.wrap("slowOrders", leftSource)
local right = Schema.wrap("fastOrders", rightSource)

local joinStream, expiredStream = JoinObservable.createJoinObservable(left, right, {
	on = "orderId", -- Join on the `orderId` field found in both streams.
	joinType = "outer", -- Outer join surfaces whichever side survives expiration.
	expirationWindow = {
		left = {
			mode = "interval",
			field = "ts", -- Use the event timestamp carried inside each record.
			offset = 5, -- Keep left entries warm for 5 seconds after their timestamp.
			currentFn = currentTime, -- Deterministic clock for the example.
		},
		right = {
			mode = "interval",
			field = "ts",
			offset = 2, -- Right cache is tighter, so stale rights fall out sooner.
			currentFn = currentTime,
		},
	},
})

local function describePair(result)
	local leftEntry = result:get("slowOrders")
	local rightEntry = result:get("fastOrders")
	local leftId = leftEntry and leftEntry.orderId or "nil"
	local rightId = rightEntry and rightEntry.orderId or "nil"
	local status
	if leftEntry and rightEntry then
		status = "MATCH"
	elseif leftEntry then
		status = "LEFT_ONLY"
	else
		status = "RIGHT_ONLY"
	end
	print(("[JOIN] %s left=%s right=%s"):format(status, leftId, rightId))
end

joinStream:subscribe(describePair, function(err)
	io.stderr:write(("Join error: %s\n"):format(err))
end, function()
	print("Join stream finished.")
end)

expiredStream:subscribe(function(packet)
	local alias = packet.alias or "unknown"
	local entry = packet.result and packet.result:get(alias)
	print(
		("[EXPIRED] alias=%s id=%s reason=%s"):format(
			alias,
			entry and entry.orderId or "nil",
			packet.reason
		)
	)
end, function(err)
	io.stderr:write(("Expired stream error: %s\n"):format(err))
end, function()
	print("Expired stream finished.")
end)

emit(leftSource, { orderId = 101, ts = 0, note = "left arrives first" })
emit(rightSource, { orderId = 101, ts = 1, note = "right within window" })
emit(rightSource, { orderId = 202, ts = 2, note = "right that will expire quickly" })
emit(leftSource, { orderId = 303, ts = 3, note = "left that will expire later" })
emit(rightSource, { orderId = 404, ts = 5, note = "fresh right, while older right may have expire" })
emit(leftSource, { orderId = 404, ts = 10, note = "late left, other lefts likely expired" })

now = 12
leftSource:onCompleted()
rightSource:onCompleted()
