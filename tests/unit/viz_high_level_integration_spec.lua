local package = require("package")
package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require("bootstrap")

local Query = require("Query")
local SchemaHelpers = require("tests.support.schema_helpers")
local QueryVizAdapter = require("viz_high_level.query_adapter")
local Runtime = require("viz_high_level.runtime")

---@diagnostic disable: undefined-global
describe("viz_high_level adapter + runtime", function()
	it("tracks window growth and layered events end-to-end", function()
		local customersSubject, customers = SchemaHelpers.subjectWithSchema("customers", { idField = "id" })
		local ordersSubject, orders = SchemaHelpers.subjectWithSchema("orders", { idField = "id" })
		local refundsSubject, refunds = SchemaHelpers.subjectWithSchema("refunds", { idField = "id" })

		local builder = Query.from(customers, "customers")
			:leftJoin(orders, "orders")
			:onSchemas({ customers = "id", orders = "customerId" })
			:leftJoin(refunds, "refunds")
			:onSchemas({ orders = "id", refunds = "orderId" })
			:window({ count = 5 })

		local adapter = QueryVizAdapter.attach(builder, { maxLayers = 5 })
		local runtime = Runtime.new({
			maxLayers = 5,
			maxColumns = 10,
			maxRows = 1,
			adjustInterval = 1,
			margin = 0,
			header = adapter.header,
		})

		local tick = 0
		local function advance()
			tick = tick + 0.5
			return tick
		end

		adapter.normalized:subscribe(function(event)
			runtime:ingest(event, advance())
		end)

		adapter.query:subscribe(function() end)

		customersSubject:onNext({ id = 50, name = "Ada" }) -- primary
		ordersSubject:onNext({ id = 101, customerId = 50 }) -- match layer 2
		refundsSubject:onNext({ id = 201, orderId = 101 }) -- match layer 1 (outermost)
		customersSubject:onNext({ id = 80, name = "Bob" }) -- expands window

		customersSubject:onCompleted()
		ordersSubject:onCompleted()
		refundsSubject:onCompleted()

			-- Window should bias to the newest primary ids within capacity (10 wide).
			local window = runtime:window()
			assert.are.equal(201, window.endId)
			assert.are.equal(192, window.startId)

			-- Primary source events dedupe per schema+id (customers/orders/refunds primaries here).
			assert.are.equal(4, #runtime.events.source)

		-- Matches should have layers clamped between 1 and 5 and include outermost refund join.
		local hasLayer1 = false
		local hasLayer2 = false
		for _, entry in ipairs(runtime.events.match) do
			assert.is_true(entry.layer >= 1 and entry.layer <= 5)
			if entry.layer == 1 then
				hasLayer1 = true
			end
			if entry.layer == 2 then
				hasLayer2 = true
			end
		end
		assert.is_true(hasLayer1)
		assert.is_true(hasLayer2)

		local snap = require("viz_high_level.headless_renderer").render(runtime, adapter.palette)
		assert.is_true(#(snap.meta.header.joins or {}) >= 2)
		local dk = snap.meta.header.joins[1].displayKey or ""
		assert.is_true(dk:find("customers%.id") ~= nil)
		assert.is_true(dk:find("orders%.customerId") ~= nil)
		local dk2 = snap.meta.header.joins[2].displayKey or ""
		assert.is_true(dk2:find("orders%.id") ~= nil)
		assert.is_true(dk2:find("refunds%.orderId") ~= nil)
		assert.are.same({ "customers" }, snap.meta.header.from)
	end)
end)
