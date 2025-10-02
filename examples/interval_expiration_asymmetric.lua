-- Expected console: match for order 101, right-only output when order 202 expires quickly, and a late left-only expiration for order 303.
require("bootstrap")
local io = require("io")

local rx = require("reactivex")
local JoinObservable = require("JoinObservable")

local now = 0
local function currentTime()
	return now
end

local function emit(subject, payload)
	now = payload.ts
	subject:onNext(payload)
end

local left = rx.Subject.create()
local right = rx.Subject.create()

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

local function describePair(pair)
	local leftId = pair.left and pair.left.orderId or "nil"
	local rightId = pair.right and pair.right.orderId or "nil"
	local status
	if pair.left and pair.right then
		status = "MATCH"
	elseif pair.left then
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

expiredStream:subscribe(function(record)
	print(
		("[EXPIRED] side=%s id=%s reason=%s"):format(
			record.side,
			record.entry and record.entry.orderId or "nil",
			record.reason
		)
	)
end, function(err)
	io.stderr:write(("Expired stream error: %s\n"):format(err))
end, function()
	print("Expired stream finished.")
end)

emit(left, { orderId = 101, ts = 0, note = "left arrives first" })
emit(right, { orderId = 101, ts = 1, note = "right within window" })
emit(right, { orderId = 202, ts = 2, note = "right that will expire quickly" })
emit(left, { orderId = 303, ts = 3, note = "left that will expire later" })
emit(right, { orderId = 404, ts = 5, note = "fresh right triggers expiration checks" })
emit(left, { orderId = 404, ts = 10, note = "left arrival forces older left entries to expire" })

now = 12
left:onCompleted()
right:onCompleted()
