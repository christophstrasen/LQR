-- Demonstrates predicate-based retention enforcing domain rules instead of simple TTLs.
-- Use for complex policy dictates which records stay eligible.

-- Expected console: left id 1 drops via policy, id 2 matches, id 3 surfaces as left-only when its partner is rejected.
require("bootstrap")
local io = require("io")

local rx = require("reactivex")
local JoinObservable = require("JoinObservable")

local trades = rx.Observable.fromTable({
	{ id = 1, status = "blocked", amount = 50 },
	{ id = 2, status = "cleared", amount = 75 },
	{ id = 3, status = "cleared", amount = 120 },
})

local approvals = rx.Observable.fromTable({
	{ id = 2, channel = "prod", reviewer = "ops" },
	{ id = 3, channel = "test", reviewer = "qa" },
})

local joinStream, expiredStream = JoinObservable.createJoinObservable(trades, approvals, {
	on = "id",
	joinType = "outer",
	expirationWindow = {
		mode = "predicate",
		-- Domain rule: only keep cleared trades and non-test approvals in the caches.
		predicate = function(entry, side)
			if side == "left" then
				return entry.status == "cleared"
			end
			return entry.channel ~= "test"
		end,
		reason = "expired_policy", -- Make it obvious why the record was dropped.
	},
})

local function describePair(pair)
	local leftId = pair.left and pair.left.id or "nil"
	local leftStatus = pair.left and pair.left.status or "n/a"
	local leftAmount = pair.left and pair.left.amount or "n/a"
	local rightId = pair.right and pair.right.id or "nil"
	local rightChannel = pair.right and pair.right.channel or "n/a"
	local rightReviewer = pair.right and pair.right.reviewer or "n/a"

	local status
	if pair.left and pair.right then
		status = "MATCH"
	elseif pair.left then
		status = "LEFT_ONLY"
	else
		status = "RIGHT_ONLY"
	end
	print(("[JOIN] %s left=%s status=%s amount=%s | right=%s channel=%s reviewer=%s"):format(
		status,
		leftId,
		leftStatus,
		leftAmount,
		rightId,
		rightChannel,
		rightReviewer
	))
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
			record.entry and record.entry.id or "nil",
			record.reason
		)
	)
end, function(err)
	io.stderr:write(("Expired stream error: %s\n"):format(err))
end, function()
	print("Expired stream finished.")
end)
