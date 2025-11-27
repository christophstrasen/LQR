local package = require("package")
package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require('LQR.bootstrap')

local Query = require("Query")
local QueryVizAdapter = require("vizualisation.core.query_adapter")
local SchemaHelpers = require("tests.support.schema_helpers")

local function rgbToHue(color)
	local r, g, b = color[1], color[2], color[3]
	local maxc = math.max(r, g, b)
	local minc = math.min(r, g, b)
	local delta = maxc - minc
	if delta == 0 then
		return 0
	end
	if maxc == r then
		return ((g - b) / delta) % 6 / 6
	elseif maxc == g then
		return ((b - r) / delta + 2) / 6
	else
		return ((r - g) / delta + 4) / 6
	end
end

local function ofType(entries, entryType)
	local filtered = {}
	for _, entry in ipairs(entries or {}) do
		if entry.type == entryType then
			filtered[#filtered + 1] = entry
		end
	end
	return filtered
end

---@diagnostic disable: undefined-global
describe("Query visualization adapter", function()
	it("emits final events after where filtering", function()
		local customers = SchemaHelpers.observableFromTable("customers", {
			{ id = 1, tier = "bronze" },
			{ id = 2, tier = "gold" },
		})
		local orders = SchemaHelpers.observableFromTable("orders", {
			{ id = 101, customerId = 1, total = 50 },
			{ id = 102, customerId = 2, total = 75 },
		})

		local builder = Query.from(customers, "customers")
			:leftJoin(orders, "orders")
			:on({ customers = { field = "id" }, orders = { field = "customerId" } })
			:where(function(row)
				return (row.orders.total or 0) >= 60
			end)

		local attachment = QueryVizAdapter.attach(builder, { maxLayers = 3 })

		local normalized = {}
		attachment.normalized:subscribe(function(event)
			normalized[#normalized + 1] = event
		end)

		local results = {}
		attachment.query:subscribe(function(result)
			results[#results + 1] = result
		end)

		assert.are.equal(1, #results)
		assert.are.equal(2, results[1]:get("customers").id)
		assert.are.equal(102, results[1]:get("orders").id)

		local finals = {}
		local joins = {}
		for _, evt in ipairs(normalized) do
			if evt.type == "joinresult" and evt.kind == "final" then
				finals[#finals + 1] = evt
			elseif evt.type == "joinresult" then
				joins[#joins + 1] = evt
			end
		end
		assert.is_true(#joins >= 1)
		assert.are.equal(1, #finals)
		local final = finals[1]
		-- Final schema/id reflect projection domain (customers), but result should carry orders.
		assert.are.equal(2, final.id)
		assert.is_not_nil(final.result)
		assert.are.equal(102, final.result:get("orders").id)
		end)

	it("emits layered events for stacked joins without changing query semantics", function()
		local customersSubject, customers = SchemaHelpers.subjectWithSchema("customers", { idField = "id" })
		local ordersSubject, orders = SchemaHelpers.subjectWithSchema("orders", { idField = "id" })
		local refundsSubject, refunds = SchemaHelpers.subjectWithSchema("refunds", { idField = "id" })

		local builder = Query.from(customers, "customers")
			:leftJoin(orders, "orders")
			:on({ customers = { field = "id" }, orders = { field = "customerId" } })
			:leftJoin(refunds, "refunds")
			:on({ orders = { field = "id" }, refunds = { field = "orderId" } })
			:joinWindow({ count = 2 })

		local attachment = QueryVizAdapter.attach(builder, { maxLayers = 5 })

		assert.are.same({ "customers", "orders", "refunds" }, attachment.primarySchemas)
		assert.is_not_nil(attachment.palette.customers)
		assert.is_not_nil(attachment.palette.orders)
		assert.is_not_nil(attachment.palette.refunds)

		local normalized = {}
		attachment.normalized:subscribe(function(event)
			normalized[#normalized + 1] = event
		end)

		local results = {}
		attachment.query:subscribe(function(result)
			results[#results + 1] = result
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

		local joins = ofType(normalized, "joinresult")
		assert.is_true(#joins >= 2)
		assert.are.equal("match", joins[1].kind)
		assert.are.equal("final", joins[#joins].kind)
		local sources = ofType(normalized, "source")
		assert.is_true(#sources >= 1)
		assert.are.equal("source", sources[1].type)
	end)

	it("generates a rainbow palette for many schemas without gaps", function()
		local builder = Query.from(SchemaHelpers.observableFromTable("a", { { id = 1 } }), "a")
			:leftJoin(SchemaHelpers.observableFromTable("b", { { id = 1 } }), "b")
			:on({ a = { field = "id" }, b = { field = "id" } })
			:leftJoin(SchemaHelpers.observableFromTable("c", { { id = 1 } }), "c")
			:on({ a = { field = "id" }, c = { field = "id" } })
			:leftJoin(SchemaHelpers.observableFromTable("d", { { id = 1 } }), "d")
			:on({ a = { field = "id" }, d = { field = "id" } })
			:leftJoin(SchemaHelpers.observableFromTable("e", { { id = 1 } }), "e")
			:on({ a = { field = "id" }, e = { field = "id" } })
			:leftJoin(SchemaHelpers.observableFromTable("f", { { id = 1 } }), "f")
			:on({ a = { field = "id" }, f = { field = "id" } })
			:leftJoin(SchemaHelpers.observableFromTable("g", { { id = 1 } }), "g")
			:on({ a = { field = "id" }, g = { field = "id" } })
			:leftJoin(SchemaHelpers.observableFromTable("h", { { id = 1 } }), "h")
			:on({ a = { field = "id" }, h = { field = "id" } })

		local attachment = QueryVizAdapter.attach(builder)
		for _, schema in ipairs(attachment.primarySchemas) do
			local color = attachment.palette[schema]
			assert.is_not_nil(color)
			assert.is_not_nil(color[1])
			assert.is_not_nil(color[2])
			assert.is_not_nil(color[3])
			assert.are.equal(1, color[4])
		end
	end)

	it("keeps schema hues away from match/expire colors", function()
		local builder = Query.from(SchemaHelpers.observableFromTable("base", { { id = 1 } }), "base")
			:leftJoin(SchemaHelpers.observableFromTable("extra", { { id = 1 } }), "extra")
			:on({ base = { field = "id" }, extra = { field = "id" } })
		local attachment = QueryVizAdapter.attach(builder)
		local reserved = { 0.0, 1 / 3 }
		local minDistance = 0.08
		for schema, color in pairs(attachment.palette) do
			if schema ~= "joined" and schema ~= "expired" and schema ~= "final" then
				local hue = rgbToHue(color)
				for _, target in ipairs(reserved) do
					local diff = math.abs(hue - target)
					diff = diff > 0.5 and (1 - diff) or diff
					assert.is_true(diff >= minDistance, string.format("schema %s hue %f too close to reserved %f", schema, hue, target))
				end
			end
		end
	end)
end)
