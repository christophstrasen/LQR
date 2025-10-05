require("bootstrap")

local io = require("io")
local JoinObservable = require("JoinObservable")
local Schema = require("JoinObservable.schema")
local rx = require("reactivex")

local function wrapTable(schemaName, rows)
	return Schema.wrap(schemaName, rx.Observable.fromTable(rows, ipairs, true))
end

local customers = wrapTable("customers", {
	{ id = 101, name = "Ada" },
	{ id = 102, name = "Ben" },
	{ id = 103, name = "Cara" },
})

local orders = wrapTable("orders", {
	{ id = 1001, customerId = 101, total = 250 },
	{ id = 1002, customerId = 103, total = 125 },
	{ id = 1003, customerId = 104, total = 99 },
})

local payments = wrapTable("payments", {
	{ id = 5001, orderId = 1001, amount = 250 },
	{ id = 5002, orderId = 1004, amount = 80 },
})

local customerOrderJoin = JoinObservable.createJoinObservable(customers, orders, {
	on = function(record)
		return record.customerId or record.id
	end,
	joinType = "left",
})

local enrichedOrdersStream = JoinObservable.chain(customerOrderJoin, {
	from = {
		{
			schema = "orders",
			renameTo = "orders_renamed",
			map = function(orderRecord, result)
				-- Explainer: enrich each forwarded order so the next join has customer context.
				orderRecord.orderId = orderRecord.orderId or orderRecord.id
				local customer = result:get("customers")
				if customer then
					orderRecord.customer = { id = customer.id, name = customer.name }
				end
				return orderRecord
			end,
		},
		{
			schema = "customers",
		},
	},
})

customerOrderJoin:subscribe(function(result)
	local customer = result:get("customers")
	local order = result:get("orders")
	if customer and order then
		print(("[CUSTOMER-ORDER] customer=%s order=%s total=%s"):format(customer.name, order.id, order.total))
	elseif customer then
		print(("[CUSTOMER-ORDER] unmatched customer=%s"):format(customer.name))
	elseif order then
		print(("[CUSTOMER-ORDER] stray order id=%s (no customer match)"):format(order.id))
	end
end, function(err)
	io.stderr:write(("Customer-order join error: %s\n"):format(err))
end, function()
	print("Customer-order join completed.")
end)

local orderPaymentJoin = JoinObservable.createJoinObservable(enrichedOrdersStream, payments, {
	on = function(record)
		return record.orderId or record.id
	end,
	joinType = "left",
})

orderPaymentJoin:subscribe(function(result)
	local enrichedOrder = result:get("orders_renamed")
	local forwardedCustomer = result:get("customers")
	local payment = result:get("payments")

	if enrichedOrder and payment then
		local customerName = forwardedCustomer and forwardedCustomer.name
			or (enrichedOrder.customer and enrichedOrder.customer.name)
			or "unknown"
		print(
			("[ORDER-PAYMENT] order=%s payment=%s amount=%s (customer=%s)"):format(
				enrichedOrder.orderId,
				payment.id,
				payment.amount,
				customerName
			)
		)
	elseif enrichedOrder then
		local customerName = forwardedCustomer and forwardedCustomer.name
			or (enrichedOrder.customer and enrichedOrder.customer.name)
			or "unknown"
		print(
			("[ORDER-PAYMENT] unmatched order=%s total=%s customer=%s"):format(
				enrichedOrder.orderId,
				enrichedOrder.total,
				customerName
			)
		)
	elseif payment then
		print(("[ORDER-PAYMENT] stray payment=%s (no order match)"):format(payment.id))
	end
end, function(err)
	io.stderr:write(("Order-payment join error: %s\n"):format(err))
end, function()
	print("Order-payment join completed.")
end)
