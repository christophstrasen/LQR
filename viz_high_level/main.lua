-- Love2D entrypoint for the high-level visualization.
package.path = "./?.lua;./?/init.lua;" .. package.path

require("bootstrap")

local Query = require("Query")
local SchemaHelpers = require("tests.support.schema_helpers")
local QueryVizAdapter = require("viz_high_level.query_adapter")
local Runtime = require("viz_high_level.runtime")
local Renderer = require("viz_high_level.headless_renderer")
local Draw = require("viz_high_level.draw")

-- Demo data: small stacked left join with deterministic ids.
local function buildDemoQuery()
	local customersSubject, customers = SchemaHelpers.subjectWithSchema("customers", { idField = "id" })
	local ordersSubject, orders = SchemaHelpers.subjectWithSchema("orders", { idField = "id" })
	local refundsSubject, refunds = SchemaHelpers.subjectWithSchema("refunds", { idField = "id" })

	local builder = Query.from(customers, "customers")
		:leftJoin(orders, "orders")
		:onSchemas({ customers = "id", orders = "customerId" })
		:leftJoin(refunds, "refunds")
		:onSchemas({ orders = "id", refunds = "orderId" })
		:window({ count = 10 })

	return {
		builder = builder,
		sources = {
			customers = customersSubject,
			orders = ordersSubject,
			refunds = refundsSubject,
		},
	}
end

local app = {
	attachment = nil,
	runtime = nil,
	subscription = nil,
}

function love.load()
	love.window.setMode(800, 600, { resizable = true })
	local demo = buildDemoQuery()
	app.attachment = QueryVizAdapter.attach(demo.builder)
	app.runtime = Runtime.new({
		maxLayers = app.attachment.maxLayers,
		palette = app.attachment.palette,
		maxColumns = 32,
		maxRows = 16,
		adjustInterval = 1.5,
	})

	app.attachment.normalized:subscribe(function(event)
		app.runtime:ingest(event, love.timer.getTime())
	end)

	-- Kick off the demo stream
	app.attachment.query:subscribe(function() end)

	-- Emit a few sample records
	local sources = demo.sources
	sources.customers:onNext({ id = 10, name = "Ada" })
	sources.orders:onNext({ id = 101, customerId = 10 })
	sources.refunds:onNext({ id = 201, orderId = 101 })
	sources.customers:onNext({ id = 50, name = "Bob" })
	sources.orders:onNext({ id = 102, customerId = 50 })
	sources.customers:onNext({ id = 90, name = "Cara" })
	sources.orders:onNext({ id = 103, customerId = 90 })
end

function love.draw()
	love.graphics.clear(0.08, 0.08, 0.08, 1)
	if not app.runtime then
		return
	end
	local snapshot = Renderer.render(app.runtime, app.attachment.palette)
	Draw.drawSnapshot(snapshot)
end

function love.quit()
	if app.subscription and app.subscription.unsubscribe then
		app.subscription:unsubscribe()
	end
end
