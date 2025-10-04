-- Demonstrates predicate-based retention enforcing domain rules instead of simple TTLs.
-- Use for complex policy dictates which records stay eligible.

-- Expected console: left id 1 drops via policy, id 2 matches, id 3 surfaces as left-only when its partner is rejected.
require("bootstrap")
local io = require("io")

local rx = require("reactivex")
local JoinObservable = require("JoinObservable")
local Schema = require("JoinObservable.schema")

local trades = Schema.wrap("trades", rx.Observable.fromTable({
	{ id = 1, status = "blocked", amount = 50 },
	{ id = 2, status = "cleared", amount = 75 },
	{ id = 3, status = "cleared", amount = 120 },
}), "trades")

local approvals = Schema.wrap("approvals", rx.Observable.fromTable({
	{ id = 2, channel = "prod", reviewer = "ops" },
	{ id = 3, channel = "test", reviewer = "qa" },
}), "approvals")

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

local function describePair(result)
	local trade = result:get("trades")
	local approval = result:get("approvals")
	local leftId = trade and trade.id or "nil"
	local leftStatus = trade and trade.status or "n/a"
	local leftAmount = trade and trade.amount or "n/a"
	local rightId = approval and approval.id or "nil"
	local rightChannel = approval and approval.channel or "n/a"
	local rightReviewer = approval and approval.reviewer or "n/a"

	local status
	if trade and approval then
		status = "MATCH"
	elseif trade then
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

expiredStream:subscribe(function(packet)
	local alias = packet.alias or "unknown"
	local entry = packet.result and packet.result:get(alias)
	print(
		("[EXPIRED] alias=%s id=%s reason=%s"):format(
			alias,
			entry and entry.id or "nil",
			packet.reason
		)
	)
end, function(err)
	io.stderr:write(("Expired stream error: %s\n"):format(err))
end, function()
	print("Expired stream finished.")
end)
