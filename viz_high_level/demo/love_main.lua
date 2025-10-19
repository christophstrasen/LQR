-- Love2D demo for the high-level visualization.
package.path = "./?.lua;./?/init.lua;" .. package.path

require("bootstrap")

local Log = require("log")
local QueryVizAdapter = require("viz_high_level.core.query_adapter")
local Runtime = require("viz_high_level.core.runtime")
local Renderer = require("viz_high_level.core.headless_renderer")
local DebugViz = require("viz_high_level.debug")
local Draw = require("viz_high_level.core.draw")
local DemoData = require("viz_high_level.demo.demo_data")

local MIX_DECAY_HALF_LIFE = 100
local app = {
	attachment = nil,
	runtime = nil,
	subscription = nil,
}
local BACKGROUND = { 0.08, 0.08, 0.08, 1 }

function love.load()
	love.window.setMode(800, 600, { resizable = true })
	Log.info("Initializing high-level viz demo")
	local demo = DemoData.build()
	app.attachment = QueryVizAdapter.attach(demo.builder)
	app.runtime = Runtime.new({
		maxLayers = app.attachment.maxLayers,
		palette = app.attachment.palette,
		adjustInterval = 1.5,
		header = app.attachment.header,
		mixDecayHalfLife = MIX_DECAY_HALF_LIFE,
	})

	app.attachment.normalized:subscribe(function(event)
		app.runtime:ingest(event, love.timer.getTime())
	end)

	app.attachment.query:subscribe(function() end)

	DemoData.emitBaseline(demo.subjects)
	DemoData.complete(demo.subjects)
end

function love.draw()
	love.graphics.clear(0.08, 0.08, 0.08, 1)
	if not app.runtime then
		return
	end
	local now = love.timer.getTime()
	local snapshot = Renderer.render(app.runtime, app.attachment.palette, now)
	DebugViz.snapshot(snapshot, { label = "love-frame" })

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
				gcText = string.format(
					"GC: interval=%.2fs%s",
					window.gc.gcIntervalSeconds,
					window.gc.gcOnInsert and " + per insert" or ""
				)
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
				wtxt = string.format(
					"Time window field=%s offset=%s",
					tostring(join.window.field),
					tostring(join.window.time)
				)
			end
			if wtxt then
				lg.printf(wtxt, 12, headerY, love.graphics.getWidth() - 24, "left")
				headerY = headerY + 18
			end
		end
	end

	local legend = snapshot.meta.legend or {}
	if #legend > 0 then
		headerY = headerY + 8
		for _, entry in ipairs(legend) do
			local rectSize = 16
			local x = 12
			lg.setColor(entry.color or { 1, 1, 1, 1 })
			lg.rectangle("fill", x, headerY, rectSize, rectSize)
			lg.setColor(1, 1, 1, 1)
			local label = string.format(
				"%s (%d total, %d projectable, %d non-projectable)",
				entry.schema,
				entry.count or 0,
				entry.projectable or 0,
				entry.nonProjectable or 0
			)
			lg.printf(label, x + rectSize + 8, headerY, love.graphics.getWidth() - x - rectSize - 16, "left")
			headerY = headerY + 20
		end
	end

	local outerLegend = snapshot.meta.outerLegend or {}
	if #outerLegend > 0 then
		headerY = headerY + 4
		for _, entry in ipairs(outerLegend) do
			local rectSize = 16
			local x = 12
			lg.setColor(entry.color or { 1, 1, 1, 1 })
			lg.rectangle("fill", x, headerY, rectSize, rectSize)
			local inset = 2
			lg.setColor(BACKGROUND)
			lg.rectangle("fill", x + inset, headerY + inset, rectSize - inset * 2, rectSize - inset * 2)
			lg.setColor(1, 1, 1, 1)
			local countLabel = ""
			if entry.kind == "match" then
				countLabel = string.format(
					" (%d projectable/%d total)",
					snapshot.meta.projectableMatchCount or 0,
					snapshot.meta.matchCount or 0
				)
			elseif entry.kind == "expire" then
				countLabel = string.format(
					" (%d projectable/%d total)",
					snapshot.meta.projectableExpireCount or 0,
					snapshot.meta.expireCount or 0
				)
			end
			local label = (entry.label or entry.kind) .. countLabel
			lg.printf(label, x + rectSize + 8, headerY, love.graphics.getWidth() - x - rectSize - 16, "left")
			headerY = headerY + 20
		end
	end

	local nonProjMatch = (snapshot.meta.matchCount or 0) - (snapshot.meta.projectableMatchCount or 0)
	local nonProjExpire = (snapshot.meta.expireCount or 0) - (snapshot.meta.projectableExpireCount or 0)
	if nonProjMatch > 0 or nonProjExpire > 0 then
		lg.printf(
			string.format("Non-projectable: match=%d, expire=%d", nonProjMatch, nonProjExpire),
			12,
			headerY,
			love.graphics.getWidth() - 24,
			"left"
		)
		headerY = headerY + 20
	end

	local metrics = Draw.metrics(snapshot)
	lg.translate(12 + (metrics.rowLabelWidth or 0), headerY + 10 + (metrics.columnLabelHeight or 0))
	Draw.drawSnapshot(snapshot, { showLabels = true })
end

function love.quit()
	if app.subscription and app.subscription.unsubscribe then
		app.subscription:unsubscribe()
	end
end
