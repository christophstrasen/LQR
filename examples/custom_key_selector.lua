-- Demonstrates functional key selectors to normalize mismatched payload shapes.
-- Reach for this when the left/right schemas encode the join key differently.

-- Expected console: one match for acct-001 and no output for other accounts.
require("bootstrap")
local io = require("io")

local rx = require("reactivex")
local JoinObservable = require("JoinObservable")

local profiles = rx.Observable.fromTable({
	{ profile = { accountId = "acct-001", name = "Ada" } },
	{ profile = { accountId = "acct-003", name = "Cara" } },
})

local billingEvents = rx.Observable.fromTable({
	{ event = { account = "acct-001" }, amount = 150 },
	{ event = { account = "acct-002" }, amount = 90 },
})

local function accountKey(record)
	return (record.profile and record.profile.accountId) or (record.event and record.event.account)
end

local joinStream = JoinObservable.createJoinObservable(profiles, billingEvents, {
	-- Functional `on` normalizes different payload shapes into a shared account id.
	on = accountKey,
	-- Inner join keeps the example focused on the matching account only.
	joinType = "inner",
})

joinStream:subscribe(function(pair)
	print(
		("[MATCH] account=%s profile=%s amount=%d"):format(
			pair.left.profile.accountId,
			pair.left.profile.name,
			pair.right.amount
		)
	)
end, function(err)
	io.stderr:write(("Join error: %s\n"):format(err))
end, function()
	print("Join completed after evaluating the functional key selector.")
end)
