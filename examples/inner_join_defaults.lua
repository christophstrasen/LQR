-- Shows the default inner join configuration so you can see the base API with zero options.
-- Useful when you need the quickest sanity check that two streams align on the same key.

-- Expected console: two match lines for ids 42 and 43, then a completion message.
require("bootstrap")
local io = require("io")

local rx = require("reactivex")
local JoinObservable = require("JoinObservable")
local Schema = require("JoinObservable.schema")

local customers = Schema.wrap("customers", rx.Observable.fromTable({
	{ id = 42, name = "Ada" },
	{ id = 43, name = "Ben" },
	{ id = 77, name = "Left only" },
}), "customers")

local orders = Schema.wrap("orders", rx.Observable.fromTable({
	{ id = 43, total = 199 },
	{ id = 42, total = 250 },
	{ id = 99, total = 75 },
}), "orders")

-- Defaults: the key selector reads the `id` field and the join type is `inner`,
-- so only rows that share an id are emitted while stray rows stay silent.
local joinStream = JoinObservable.createJoinObservable(customers, orders)

joinStream:subscribe(function(result)
	local customer = result:get("customers")
	local order = result:get("orders")
	if customer and order then
		print(("[MATCH] id=%d customer=%s total=%d"):format(customer.id, customer.name, order.total))
	end
end, function(err)
	io.stderr:write(("Join error: %s\n"):format(err))
end, function()
	print("Join finished with only matched rows.")
end)
