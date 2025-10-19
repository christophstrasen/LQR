local package = require("package")
package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require("bootstrap")

local Runtime = require("viz_high_level.core.runtime")

---@diagnostic disable: undefined-global
describe("viz_high_level runtime", function()
	it("expands window with hysteresis and clamps to max size", function()
		local runtime = Runtime.new({
			maxColumns = 10,
			maxRows = 1,
			adjustInterval = 2,
			margin = 0,
			startId = 1,
			now = 0,
		})

		runtime:ingest({ type = "source", id = 50 }, 0) -- too soon to adjust
		local window = runtime:window()
		assert.are.equal(1, window.startId)
		assert.are.equal(10, window.endId)

		runtime:ingest({ type = "source", id = 55 }, 2.5) -- adjusts after interval
		window = runtime:window()
		assert.are.equal(50, window.startId)
		assert.are.equal(59, window.endId)

		runtime:ingest({ type = "source", id = 80 }, 2.7) -- within hysteresis window, no change
		window = runtime:window()
		assert.are.equal(50, window.startId)
		assert.are.equal(59, window.endId)

		runtime:ingest({ type = "source", id = 90 }, 5) -- adjust again, clamp span to 10
		window = runtime:window()
		assert.are.equal(81, window.startId)
		assert.are.equal(90, window.endId)
	end)

	it("clamps match/expire layers to maxLayers", function()
		local runtime = Runtime.new({ maxLayers = 5 })
		runtime:ingest({ type = "joinresult", kind = "match", layer = 10 })
		runtime:ingest({ type = "expire", layer = 0 })

		assert.are.equal(1, #runtime.events.match)
		assert.are.equal(5, runtime.events.match[1].layer)
		assert.are.equal(1, #runtime.events.expire)
		assert.are.equal(1, runtime.events.expire[1].layer)
	end)

	it("auto zooms between 10x10 and 100x100", function()
		local runtime = Runtime.new({ adjustInterval = 0.1, mixDecayHalfLife = 5 })
		for i = 1, 20 do
			runtime:ingest({ type = "source", id = i, projectionKey = i, projectable = true }, i * 0.11)
		end
		local window = runtime:window()
		assert.are.equal(10, window.columns)
		assert.are.equal(10, window.rows)

		for i = 21, 140 do
			runtime:ingest({ type = "source", id = i, projectionKey = i, projectable = true }, 2 + i * 0.01)
		end
		window = runtime:window()
		assert.are.equal(100, window.columns)
		assert.are.equal(100, window.rows)

		-- Move time far forward so earlier ids expire and we shrink again.
		runtime:ingest({ type = "source", id = 1000, projectionKey = 1000, projectable = true }, 100)
		window = runtime:window()
		assert.are.equal(10, window.columns)
		assert.are.equal(10, window.rows)
	end)

	it("compresses window to latest ids when span exceeds capacity", function()
		local runtime = Runtime.new({ adjustInterval = 0, mixDecayHalfLife = 100 })
		-- Populate more than 10*10 ids to force switch to large grid.
		for i = 1, 200 do
			runtime:ingest({ type = "source", id = i, projectionKey = i, projectable = true }, i)
		end
		local window = runtime:window()
		assert.are.equal(100, window.columns)
		assert.are.equal(100, window.rows)
		-- Now ingest a huge spike so span exceeds even 100x100.
		for i = 10000, 10550 do
			runtime:ingest({ type = "source", id = i, projectionKey = i, projectable = true }, i)
		end
		window = runtime:window()
		assert.are.equal(100, window.columns)
		assert.are.equal(100, window.rows)
		assert.is_true(window.startId >= 0)
		assert.are.equal(window.startId + (window.columns * window.rows) - 1, window.endId)
		assert.is_true(window.startId >= 10000 - (window.columns * window.rows))
	end)

	it("derives margin from grid size when percent configured", function()
		local runtime = Runtime.new({ adjustInterval = 0, mixDecayHalfLife = 5 })
		for i = 1, 15 do
			runtime:ingest({ type = "source", id = i, projectionKey = i, projectable = true }, i * 0.1)
		end
		local window = runtime:window()
		assert.are.equal(20, window.margin) -- 2 columns * 10 rows
		assert.are.equal(0.2, window.marginPercent)
		for i = 16, 150 do
			runtime:ingest({ type = "source", id = i, projectionKey = i, projectable = true }, i * 0.1)
		end
		window = runtime:window()
		assert.are.equal(2000, window.margin) -- 20 columns * 100 rows
	end)

	it("honors explicit absolute margin override", function()
		local runtime = Runtime.new({ adjustInterval = 0, margin = 5 })
		runtime:ingest({ type = "source", id = 10, projectionKey = 10, projectable = true }, 0)
		runtime:ingest({ type = "source", id = 20, projectionKey = 20, projectable = true }, 1)
		local window = runtime:window()
		assert.are.equal(5, window.margin)
	end)
end)
