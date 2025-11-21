local package = require("package")
package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require("bootstrap")

local Query = require("Query")
local SchemaHelpers = require("tests.support.schema_helpers")

local function collect(observable)
	local out = {}
	observable:subscribe(function(value)
		out[#out + 1] = value
	end)
	return out
end

---@diagnostic disable: undefined-global
describe("Query WHERE clause", function()
	it("filters joined rows using the row view", function()
		local customersSubject, customers = SchemaHelpers.subjectWithSchema("customers", { idField = "id" })
		local ordersSubject, orders = SchemaHelpers.subjectWithSchema("orders", { idField = "id" })

		local query = Query.from(customers, "customers")
			:innerJoin(orders, "orders")
			:on({ customers = { field = "id" }, orders = { field = "customerId" } })
			:where(function(r)
				return r.customers.status == "active" and (r.orders.amount or 0) > 10
			end)

		local results = collect(query)

		customersSubject:onNext({ id = 1, status = "active" })
		customersSubject:onNext({ id = 2, status = "inactive" })
		ordersSubject:onNext({ id = 101, customerId = 1, amount = 5 })
		ordersSubject:onNext({ id = 102, customerId = 1, amount = 20 })
		ordersSubject:onNext({ id = 103, customerId = 2, amount = 50 })

		assert.are.equal(1, #results)
		local match = results[1]
		assert.are.equal(1, match:get("customers").id)
		assert.are.equal(102, match:get("orders").id)
	end)

	it("treats missing schemas as empty tables for left joins", function()
		local customersSubject, customers = SchemaHelpers.subjectWithSchema("customers", { idField = "id" })
		local ordersSubject, orders = SchemaHelpers.subjectWithSchema("orders", { idField = "id" })

		local query = Query.from(customers, "customers")
			:leftJoin(orders, "orders")
			:on({ customers = { field = "id" }, orders = { field = "customerId" } })
			:where(function(r)
				-- orders is {} when absent; accessing id is safe
				return r.orders.id == nil and r.customers.segment == "trial"
			end)

		local rows = {}
		query:subscribe(function(result)
			rows[#rows + 1] = result
		end)

		customersSubject:onNext({ id = 1, segment = "trial" }) -- no order
		customersSubject:onNext({ id = 2, segment = "pro" })
		ordersSubject:onNext({ id = 201, customerId = 2 })
		customersSubject:onCompleted()
		ordersSubject:onCompleted()

		assert.are.equal(1, #rows)
		local row = rows[1]
		assert.are.equal(1, row:get("customers").id)
		assert.is_nil(row:get("orders"))

		-- ensure row view exposed orders as an empty table during predicate evaluation
		-- (if it were missing, predicate would have errored)
	end)

	it("filters selection-only queries", function()
		local subject, source = SchemaHelpers.subjectWithSchema("customers", { idField = "id" })

		local seenRawResults = {}
		local query = Query.from(source, "customers")
			:where(function(r)
				if r._raw_result then
					seenRawResults[#seenRawResults + 1] = r._raw_result
				end
				return (r.customers.id or 0) > 1
			end)

		local results = collect(query)

		subject:onNext({ id = 1 })
		subject:onNext({ id = 2 })
		subject:onNext({ id = 3 })

		assert.are.equal(2, #results)
		local ids = { results[1]:get("customers").id, results[2]:get("customers").id }
		table.sort(ids)
		assert.are.same({ 2, 3 }, ids)
		assert.are.equal(3, #seenRawResults) -- predicate sees every emission, even filtered-out ones
	end)

	it("marks describe with a where flag", function()
		local source = SchemaHelpers.observableFromTable("customers", { { id = 1 } })
		local plan = Query.from(source, "customers")
			:where(function()
				return true
			end)
			:describe()
		assert.is_true(plan.where)
	end)

	it("errors on multiple where calls", function()
		local source = SchemaHelpers.observableFromTable("customers", { { id = 1 } })
		assert.has_error(function()
			Query.from(source, "customers")
				:where(function()
					return true
				end)
				:where(function()
					return false
				end)
		end)
	end)
end)
