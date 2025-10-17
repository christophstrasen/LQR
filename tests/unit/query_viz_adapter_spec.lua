local package = require("package")
package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require("bootstrap")

local Query = require("Query")
local QueryVizAdapter = require("viz_high_level.query_adapter")
local SchemaHelpers = require("tests.support.schema_helpers")

---@diagnostic disable: undefined-global
describe("Query visualization adapter", function()
	it("emits layered events for stacked joins without changing query semantics", function()
		local customersSubject, customers = SchemaHelpers.subjectWithSchema("customers", { idField = "id" })
		local ordersSubject, orders = SchemaHelpers.subjectWithSchema("orders", { idField = "id" })
		local refundsSubject, refunds = SchemaHelpers.subjectWithSchema("refunds", { idField = "id" })

		local builder = Query.from(customers, "customers")
			:leftJoin(orders, "orders")
			:onSchemas({ customers = "id", orders = "customerId" })
			:leftJoin(refunds, "refunds")
			:onSchemas({ orders = "id", refunds = "orderId" })
			:window({ count = 2 })

		local attachment = QueryVizAdapter.attach(builder, { maxLayers = 5 })

		assert.are.same({ "customers", "orders", "refunds" }, attachment.primarySchemas)
		assert.is_not_nil(attachment.palette.customers)
		assert.is_not_nil(attachment.palette.orders)
		assert.is_not_nil(attachment.palette.refunds)

		local results = {}
		attachment.query:subscribe(function(result)
			results[#results + 1] = result
		end)

		local normalized = {}
		attachment.normalized:subscribe(function(event)
			normalized[#normalized + 1] = event
		end)

		customersSubject:onNext({ id = 1, name = "Ada" })
		ordersSubject:onNext({ id = 101, customerId = 1 })
		refundsSubject:onNext({ id = 201, orderId = 101 }) -- matches order 101 at outermost layer
		ordersSubject:onNext({ id = 102, customerId = 1 }) -- unmatched refund path

		customersSubject:onCompleted()
		ordersSubject:onCompleted()
		refundsSubject:onCompleted()

		-- Query semantics remain.
		assert.are.equal(2, #results)
		assert.are.equal(1, results[1]:get("customers").id)
		assert.are.equal(101, results[1]:get("orders").id)
		assert.are.equal(201, results[1]:get("refunds").id)
		assert.are.equal(1, results[2]:get("customers").id)
		assert.are.equal(102, results[2]:get("orders").id)
		assert.is_nil(results[2]:get("refunds"))

		local function ofType(kind)
			local filtered = {}
			for _, entry in ipairs(normalized) do
				if entry.type == kind then
					filtered[#filtered + 1] = entry
				end
			end
			return filtered
		end

		local sources = ofType("source")
		assert.are.same(4, #sources) -- 1 customer, 2 orders, 1 refund (primaries only, deduped)

		local matches = ofType("match")
		assert.is_true(#matches >= 2)
		for _, entry in ipairs(matches) do
			assert.is_true(entry.layer >= 1 and entry.layer <= 5)
		end

		local outerMatch
		for _, entry in ipairs(matches) do
			if entry.layer == 1 and entry.left and entry.left.schema == "orders" then
				outerMatch = entry
				break
			end
		end
		assert.is_not_nil(outerMatch, "expected outermost (layer 1) match for refund join")

		local expires = ofType("expire")
		assert.is_true(#expires >= 1)
		local hasOuterExpire = false
		for _, entry in ipairs(expires) do
			assert.is_true(entry.layer >= 1 and entry.layer <= 5)
			if entry.layer == 1 then
				hasOuterExpire = true
			end
		end
		assert.is_true(hasOuterExpire) -- final join emits expiration on completion
	end)
end)
