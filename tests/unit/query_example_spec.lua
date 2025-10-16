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
end)
