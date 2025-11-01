local package = require("package")
package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require("bootstrap")

local Query = require("Query")
local SchemaHelpers = require("tests.support.schema_helpers")

---@diagnostic disable: undefined-global
describe("Query high-level example", function()
	it("joins and emits expired/unmatched with a count window", function()
		local leftSubject, customers = SchemaHelpers.subjectWithSchema("customers", { idField = "id" })
		local rightSubject, orders = SchemaHelpers.subjectWithSchema("orders", { idField = "id" })

		local query = Query.from(customers, "customers")
			:leftJoin(orders, "orders")
			:onSchemas({ customers = "id", orders = "customerId" })
			:window({ count = 1 }) -- keep only the most recent per side

		local results = {}
		local expiredPackets = {}

		query:subscribe(function(result)
			results[#results + 1] = result
		end)

		query:expired():subscribe(function(packet)
			expiredPackets[#expiredPackets + 1] = packet
		end)

		-- Two customers, no orders. First customer will be evicted when the second arrives.
		leftSubject:onNext({ id = 1, name = "Ada" })
		leftSubject:onNext({ id = 2, name = "Bob" })

		leftSubject:onCompleted()
		rightSubject:onCompleted()

		-- Results: unmatched projections emitted on eviction and completion.
		assert.are.equal(2, #results)
		assert.are.same(1, results[1]:get("customers").id)
		assert.is_nil(results[1]:get("orders"))
		assert.are.same(2, results[2]:get("customers").id)
		assert.is_nil(results[2]:get("orders"))

		-- Expired packets track eviction/completion reasons.
		assert.are.equal(2, #expiredPackets)
		local expiredIds, reasons = {}, {}
		for i, packet in ipairs(expiredPackets) do
			local entry = packet.result and packet.result:get(packet.schema)
			expiredIds[i] = entry and entry.id or nil
			reasons[i] = packet.reason
		end

		assert.are.same({ 1, 2 }, expiredIds)
		assert.are.same({ "evicted", "completed" }, reasons)
	end)

	it("handles stacked left joins with matches and unmatched carry-over", function()
		local customersSubject, customers = SchemaHelpers.subjectWithSchema("customers", { idField = "id" })
		local ordersSubject, orders = SchemaHelpers.subjectWithSchema("orders", { idField = "id" })
		local refundsSubject, refunds = SchemaHelpers.subjectWithSchema("refunds", { idField = "id" })

		local query = Query.from(customers, "customers")
			:leftJoin(orders, "orders")
			:onSchemas({ customers = "id", orders = "customerId" })
			:leftJoin(refunds, "refunds")
			:onSchemas({ orders = "id", refunds = "orderId" })
			:window({ count = 2 }) -- keep a small buffer so flush emits on completion

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
