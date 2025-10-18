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
local BACKGROUND = { 0.08, 0.08, 0.08, 1 }

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
		header = app.attachment.header,
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

	-- Header
	local lg = love.graphics
	lg.setColor(1, 1, 1, 1)
	local headerY = 10
	local headerData = snapshot.meta.header or {}
	local window = headerData.window or snapshot.window
	if window then
		local rangeText = string.format(
			"Showing records on id range %s-%s (grid %dx%d)",
			tostring(window.startId),
			tostring(window.endId),
			window.columns or 0,
			window.rows or 0
		)
		lg.printf(rangeText, 12, headerY, love.graphics.getWidth() - 24, "left")
		headerY = headerY + 22
		if window.gc then
			local gcText
			if window.gc.gcIntervalSeconds and window.gc.gcIntervalSeconds > 0 then
				gcText = string.format("GC: interval=%.2fs%s", window.gc.gcIntervalSeconds, window.gc.gcOnInsert and " + per insert" or "")
			elseif window.gc.gcOnInsert == false then
				gcText = "GC: onComplete only"
			else
				gcText = "GC: per insert"
			end
			lg.printf(gcText, 12, headerY, love.graphics.getWidth() - 24, "left")
			headerY = headerY + 22
		end
	end
	if headerData.from and #headerData.from > 0 then
		local fromText = string.format("from %s", table.concat(headerData.from, ", "))
		lg.printf(fromText, 12, headerY, love.graphics.getWidth() - 24, "left")
		headerY = headerY + 22
	end

	local joins = headerData.joins or {}
	for _, join in ipairs(joins) do
		local keyDesc = join.displayKey or "id"
		local joinText = string.format("%s join %s on %s", join.type or "join", join.source or "right", keyDesc)
		lg.printf(joinText, 12, headerY, love.graphics.getWidth() - 24, "left")
		headerY = headerY + 18
		if join.window then
			local wtxt
			if join.window.mode == "count" then
				wtxt = string.format("Count window=%s", tostring(join.window.count))
			elseif join.window.mode == "time" then
				wtxt = string.format("Time window field=%s offset=%s", tostring(join.window.field), tostring(join.window.time))
			end
			if wtxt then
				lg.printf(wtxt, 12, headerY, love.graphics.getWidth() - 24, "left")
				headerY = headerY + 18
			end
		end
	end

	-- Legend (schemas)
	local legend = snapshot.meta.legend or {}
	if #legend > 0 then
		headerY = headerY + 8
		for _, entry in ipairs(legend) do
			local rectSize = 16
			local x = 12
			lg.setColor(entry.color or { 1, 1, 1, 1 })
			lg.rectangle("fill", x, headerY, rectSize, rectSize)
			lg.setColor(1, 1, 1, 1)
			local label = string.format("%s (%dx)", entry.schema, entry.count or 0)
			lg.printf(label, x + rectSize + 8, headerY, love.graphics.getWidth() - x - rectSize - 16, "left")
			headerY = headerY + 20
		end
	end

	-- Outer legend (match/expire)
	local outerLegend = snapshot.meta.outerLegend or {}
	if #outerLegend > 0 then
		headerY = headerY + 4
		for _, entry in ipairs(outerLegend) do
			local rectSize = 16
			local x = 12
			lg.setColor(entry.color or { 1, 1, 1, 1 })
			lg.rectangle("fill", x, headerY, rectSize, rectSize)
			-- Hollow inner to emphasize outer box
			local inset = 2
			lg.setColor(BACKGROUND)
			lg.rectangle("fill", x + inset, headerY + inset, rectSize - inset * 2, rectSize - inset * 2)
			lg.setColor(1, 1, 1, 1)
			local label = entry.label or entry.kind
			lg.printf(label, x + rectSize + 8, headerY, love.graphics.getWidth() - x - rectSize - 16, "left")
			headerY = headerY + 20
		end
	end

	lg.translate(12, headerY + 10)
	Draw.drawSnapshot(snapshot)
end

function love.quit()
	if app.subscription and app.subscription.unsubscribe then
		app.subscription:unsubscribe()
	end
end
