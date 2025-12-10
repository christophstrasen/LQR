local package = require("package")
package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require('LQR.bootstrap')

local Query = require("LQR.Query")
local SchemaHelpers = require("tests.support.schema_helpers")
local QueryVizAdapter = require("vizualisation.core.query_adapter")

---@diagnostic disable: undefined-global
describe("Query projection map", function()
	it("derives projection fields from the first join on map", function()
		local customers = SchemaHelpers.observableFromTable("customers", { { id = 1 } })
		local orders = SchemaHelpers.observableFromTable("orders", { { id = 1, customerId = 1 } })
		local refunds = SchemaHelpers.observableFromTable("refunds", { { id = 2, orderId = 1 } })

		local builder = Query.from(customers, "customers")
			:leftJoin(orders, "orders")
			:using({ customers = { field = "id" }, orders = { field = "customerId" } })
			:leftJoin(refunds, "refunds")
			:using({ orders = { field = "id" }, refunds = { field = "orderId" } })

		local attachment = QueryVizAdapter.attach(builder)
		local projection = attachment.header.projection

		assert.are.equal("customers", projection.domain)
		assert.are.equal("id", projection.field)
		assert.are.same({
			customers = "id",
			orders = "customerId",
		}, projection.fields)
	end)
end)
