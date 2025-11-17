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
describe("Query grouping (high level)", function()
	it("groups a single stream with count window and aggregates", function()
		local customersSubject, customers = SchemaHelpers.subjectWithSchema("customers", { idField = "id" })

		local grouped = Query.from(customers, "customers")
			:groupBy("customers_grouped", function(row)
				return row.customers.id
			end)
			:groupWindow({ count = 2 })
			:aggregates({
				sum = { "customers.value" },
				avg = { "customers.value" },
			})
			:having(function(g)
				return (g._count or 0) >= 2
			end)

		local aggregates = collect(grouped)

		customersSubject:onNext({ id = 1, value = 10 })
		customersSubject:onNext({ id = 1, value = 20 })
		customersSubject:onNext({ id = 1, value = 30 })

		-- HAVING drops the first group emission (count=1); we expect two kept aggregates.
		assert.are.equal(2, #aggregates)
		local last = aggregates[#aggregates]
		assert.are.equal(2, last._count)
		assert.are.equal(50, last.customers._sum.value)
		assert.are.equal(25, last.customers._avg.value)
		assert.are.equal("customers_grouped", last.RxMeta.schema)
	end)

	it("supports HAVING over enriched events", function()
		local customersSubject, customers = SchemaHelpers.subjectWithSchema("customers", { idField = "id" })

		local grouped = Query.from(customers, "customers")
			:groupByEnrich("_groupBy:customers", function(row)
				return row.customers.id
			end)
			:groupWindow({ count = 2 })
			:aggregates({
				count = true,
				sum = { "customers.value" },
			})
			:having(function(row)
				return (row._count or 0) >= 2
			end)

		local enriched = collect(grouped)

		customersSubject:onNext({ id = 1, value = 10 })
		customersSubject:onNext({ id = 1, value = 20 })
		customersSubject:onNext({ id = 1, value = 30 })

		assert.are.equal(2, #enriched)
		local last = enriched[#enriched]
		assert.are.equal(2, last._count)
		assert.are.equal(30, last.customers.value)
		assert.are.equal(50, last.customers._sum.value)
		assert.is_table(last["_groupBy:customers"])
		assert.are.equal(2, last["_groupBy:customers"]._count)
	end)
end)
