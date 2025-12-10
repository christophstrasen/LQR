local package = require("package")
package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require('LQR.bootstrap')

local Query = require("LQR.Query")
local SchemaHelpers = require("tests.support.schema_helpers")

---@diagnostic disable: undefined-global
describe("Query high-level example", function()
	it("handles stacked left joins with matches and unmatched carry-over", function()
		local customersSubject, customers = SchemaHelpers.subjectWithSchema("customers", { idField = "id" })
		local ordersSubject, orders = SchemaHelpers.subjectWithSchema("orders", { idField = "id" })
		local refundsSubject, refunds = SchemaHelpers.subjectWithSchema("refunds", { idField = "id" })

		local query = Query.from(customers, "customers")
			:leftJoin(orders, "orders")
			:using({ customers = { field = "id" }, orders = { field = "customerId" } })
			:leftJoin(refunds, "refunds")
			:using({ orders = { field = "id" }, refunds = { field = "orderId" } })
			:joinWindow({ count = 2 }) -- keep a small buffer so flush emits on completion

		local results, expiredPackets = {}, {}
		query:subscribe(function(result)
			results[#results + 1] = result
		end)
		query:expired():subscribe(function(packet)
			expiredPackets[#expiredPackets + 1] = packet
		end)

		-- Customer with two orders, only one refunded.
		customersSubject:onNext({ id = 1, name = "Ada" })
		ordersSubject:onNext({ id = 101, customerId = 1 })
		refundsSubject:onNext({ id = 201, orderId = 101 }) -- matches order 101
		ordersSubject:onNext({ id = 102, customerId = 1 }) -- no refund

		customersSubject:onCompleted()
		ordersSubject:onCompleted()
		refundsSubject:onCompleted()

		-- Expect one full match (customer+order+refund) and one unmatched order (carrying customer).
		assert.are.equal(2, #results)
		local match = results[1]
		assert.are.equal(1, match:get("customers").id)
		assert.are.equal(101, match:get("orders").id)
		assert.are.equal(201, match:get("refunds").id)

		local unmatched = results[2]
		assert.are.equal(1, unmatched:get("customers").id)
		assert.are.equal(102, unmatched:get("orders").id)
		assert.is_nil(unmatched:get("refunds"))

		-- Expired packets include the unmatched order on completion (and now also matched rows on flush).
		assert.is_true(#expiredPackets >= 1)
		local ids = {}
		local reasons = {}
		for _, packet in ipairs(expiredPackets) do
			local entry = packet.result:get(packet.schema)
			ids[#ids + 1] = entry and entry.id or nil
			reasons[#reasons + 1] = packet.reason
		end
		-- Ensure the unmatched order 102 is present as completed.
		local foundUnmatched = false
		for i = 1, #ids do
			if ids[i] == 102 and reasons[i] == "completed" then
				foundUnmatched = true
				break
			end
		end
		assert.is_true(foundUnmatched)
	end)
end)
