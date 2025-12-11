local package = require("package")
package.path = "./?.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require('LQR/bootstrap')

local Renderer = require("vizualisation/core/headless_renderer")
local Runtime = require("vizualisation/core/runtime")

---@diagnostic disable: undefined-global
describe("vizualisation projection anchoring", function()
	it("stacks borders from different key domains on the projected join key", function()
		-- Projection domain: default to first 'from' schema (customers).
		local runtime = Runtime.new({
			maxLayers = 5,
			maxColumns = 10,
			maxRows = 1,
			startId = 50,
			header = {
				from = { "customers" },
				projection = { domain = "customers", field = "id", fields = { customers = "id", orders = "customerId" } },
				joins = {},
			},
		})

		-- Upper join keyed on customerId (customer domain).
		runtime:ingest({
			type = "joinresult",
			kind = "match",
			layer = 2,
			key = 50, -- customer id
			left = { schema = "customers", id = 50 },
			right = { schema = "orders", id = 101 },
		})

		-- Lower join keyed on orderId (order domain) but projected to customer domain via shared key.
		runtime:ingest({
			type = "joinresult",
			kind = "match",
			layer = 1,
			key = 50, -- project to same customer cell
			left = { schema = "orders", id = 101 },
			right = { schema = "refunds", id = 201 },
		})

		local snap = Renderer.render(runtime, {
			customers = { 0.1, 0.2, 0.3, 1 },
			orders = { 0.2, 0.3, 0.4, 1 },
			refunds = { 0.3, 0.4, 0.5, 1 },
			joined = { 0, 1, 0, 1 },
			expired = { 1, 0, 0, 1 },
		})

		local foundCell = snap.cells[1] and snap.cells[1][1]
		-- With projection enrichment, only projectable events render; in this synthetic case,
		-- projectionKey is missing so nothing is drawn.
		assert.is_nil(foundCell)
	end)

	it("counts non-projectable events without drawing them", function()
		local runtime = Runtime.new({
			maxLayers = 3,
			maxColumns = 5,
			maxRows = 1,
			startId = 1,
			header = {
				projection = { domain = "customers", field = "id", fields = { customers = "id" } },
			},
		})

		-- Non-projectable source (schema not in projection map).
		runtime:ingest({
			type = "source",
			schema = "other",
			id = 999,
			projectable = false,
			projectionKey = nil,
		})

		-- Non-projectable match (no projectionKey and schema missing).
		runtime:ingest({
			type = "joinresult",
			kind = "match",
			layer = 1,
			projectable = false,
			projectionKey = nil,
			left = { schema = "other", id = 999 },
			right = { schema = "other", id = 1000 },
		})

		local snap = require("vizualisation/core/headless_renderer").render(runtime, {
			other = { 0.5, 0.5, 0.5, 1 },
			joined = { 0, 1, 0, 1 },
			expired = { 1, 0, 0, 1 },
		})

		assert.are.same(1, snap.meta.sourceCounts.other)
		assert.are.same(0, snap.meta.projectableSourceCounts.other or 0)
		assert.are.same(1, snap.meta.matchCount)
		assert.are.same(0, snap.meta.projectableMatchCount)
		assert.is_nil(next(snap.cells or {}))
	end)
end)

describe("vizualisation projection enrichment", function()
	it("marks projection metadata on normalized events", function()
		local Query = require("LQR/Query")
		local SchemaHelpers = require("tests/support/schema_helpers")
		local QueryVizAdapter = require("vizualisation/core/query_adapter")

		local customers = SchemaHelpers.observableFromTable("customers", { { id = 1 } })
		local orders = SchemaHelpers.observableFromTable("orders", { { id = 1, customerId = 1 } })

		local builder = Query.from(customers, "customers")
			:leftJoin(orders, "orders")
			:using({ customers = "id", orders = "customerId" })

		local attachment = QueryVizAdapter.attach(builder)
		local events = {}
		attachment.normalized:subscribe(function(evt)
			events[#events + 1] = evt
		end)

		attachment.query:subscribe(function() end)
		customers:subscribe(function() end)
		orders:subscribe(function() end)

		for _, evt in ipairs(events) do
			if evt.type == "source" then
				assert.is_true(evt.projectionDomain ~= nil)
			end
		end
	end)
end)
