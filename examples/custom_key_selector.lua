-- Demonstrates functional key selectors to normalize mismatched payload shapes.
-- Reach for this when the left/right schemas encode the join key differently.

-- Expected console: one match for acct-001 and no output for other accounts.
require("bootstrap")
local io = require("io")

local rx = require("reactivex")
local JoinObservable = require("JoinObservable.init")
local Schema = require("JoinObservable.schema")

local function accountKey(record)
	return (record.profile and record.profile.accountId) or (record.event and record.event.account)
end

local profiles = Schema.wrap("profiles", rx.Observable.fromTable({
	{ profile = { accountId = "acct-001", name = "Ada" } },
	{ profile = { accountId = "acct-003", name = "Cara" } },
}), {
	idSelector = accountKey,
})

local billingEvents = Schema.wrap("billingEvents", rx.Observable.fromTable({
	{ event = { account = "acct-001" }, amount = 150 },
	{ event = { account = "acct-002" }, amount = 90 },
}), {
	idSelector = accountKey,
})

local joinStream = JoinObservable.createJoinObservable(profiles, billingEvents, {
	-- Functional `on` normalizes different payload shapes into a shared account id.
	on = accountKey,
	-- Inner join keeps the example focused on the matching account only.
	joinType = "inner",
})

joinStream:subscribe(function(result)
	local profile = result:get("profiles")
	local billing = result:get("billingEvents")
	if profile and billing then
		print(
			("[MATCH] account=%s profile=%s amount=%d"):format(
				profile.profile.accountId,
				profile.profile.name,
				billing.amount
			)
		)
	end
end, function(err)
	io.stderr:write(("Join error: %s\n"):format(err))
end, function()
	print("Join completed after evaluating the functional key selector.")
end)
