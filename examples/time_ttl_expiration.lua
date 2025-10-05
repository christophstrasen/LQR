-- Shows the `mode = "time"` convenience (wrapper over `interval`) so you can reason about TTLs on records carrying `time`.
-- Use this pattern when events already include timestamps and you just need a sliding TTL.

-- Expected console: left id 1 expires with reason expired_time, ids 2 and 3 match successfully.
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
	now = payload.time
	subject:onNext(payload)
end

local leftSource = rx.Subject.create()
local rightSource = rx.Subject.create()
local left = Schema.wrap("invoices", leftSource)
local right = Schema.wrap("payments", rightSource)

local joinStream, expiredStream = JoinObservable.createJoinObservable(left, right, {
	on = "id",
	joinType = "outer",
	expirationWindow = {
		mode = "time",
		ttl = 3, -- Only keep records warm for 3 seconds past `record.time`.
		currentFn = currentTime, -- Custom clock so we can advance time manually, otherwise uses os.time() as default
	},
})

local function describePair(result)
	local invoice = result:get("invoices")
	local payment = result:get("payments")
	local leftId = invoice and invoice.id or "nil"
	local rightId = payment and payment.id or "nil"
	print(("[JOIN] left=%s right=%s"):format(leftId, rightId))
end

joinStream:subscribe(describePair, function(err)
	io.stderr:write(("Join error: %s\n"):format(err))
end, function()
	print("Join stream finished.")
end)

expiredStream:subscribe(function(packet)
	local schemaName = packet.schema or "unknown"
	local entry = packet.result and packet.result:get(schemaName)
	print(
		("[EXPIRED] schema=%s id=%s reason=%s"):format(
			schemaName,
			entry and entry.id or "nil",
			packet.reason
		)
	)
end, function(err)
	io.stderr:write(("Expired stream error: %s\n"):format(err))
end, function()
	print("Expired stream finished.")
end)

emit(leftSource, { id = 1, kind = "invoice", time = 0 })
emit(rightSource, { id = 2, kind = "payment", time = 1 })
emit(leftSource, { id = 2, kind = "invoice", time = 2 })
emit(leftSource, { id = 3, kind = "invoice", time = 6 })
emit(rightSource, { id = 3, kind = "payment", time = 6 })

now = 6
leftSource:onCompleted()
rightSource:onCompleted()
