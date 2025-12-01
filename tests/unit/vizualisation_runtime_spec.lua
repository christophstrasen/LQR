local package = require("package")
package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require('LQR.bootstrap')

local Runtime = require("vizualisation.core.runtime")

---@diagnostic disable: undefined-global
describe("vizualisation runtime", function()
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

	it("auto zooms between 10x10 and 100x100 based on span only", function()
		-- adjustInterval=0 disables hysteresis so the span-based zoom reacts immediately,
		-- avoiding timing noise in this unit test. Production defaults use >0 to prevent thrash.
		local runtime = Runtime.new({
			adjustInterval = 0,
			visualsTTL = 0.2,
			activeCellTTLFactor = 4, -- keep actives visible long enough for span jump in test
		})
		for i = 1, 50 do
			runtime:ingest({ type = "source", id = i, projectionKey = i, projectable = true }, i * 0.1)
		end
		local window = runtime:window()
		assert.are.equal(10, window.columns)
		assert.are.equal(10, window.rows)

		-- Stretch the span so min/max exceed the small visible span -> zoom to large.
		runtime:ingest({ type = "source", id = 1, projectionKey = 1, projectable = true }, 6)
		runtime:ingest({ type = "source", id = 200, projectionKey = 200, projectable = true }, 6.1)
		window = runtime:window()
		assert.are.equal(100, window.columns)
		assert.are.equal(100, window.rows)

		-- Advance time so earlier ids fade and span collapses -> zoom back to small.
		runtime:ingest({ type = "source", id = 5, projectionKey = 5, projectable = true }, 10)
		window = runtime:window()
		assert.are.equal(10, window.columns)
		assert.are.equal(10, window.rows)
	end)

	it("compresses window to latest ids when span exceeds capacity", function()
		local runtime = Runtime.new({
			adjustInterval = 0,
			visualsTTL = 100,
			activeCellTTLFactor = 4,
		})
		-- Minimal span that exceeds 100x100 range forces compressed mode immediately.
		runtime:ingest({ type = "source", id = 0, projectionKey = 0, projectable = true }, 0)
		runtime:ingest({ type = "source", id = 20000, projectionKey = 20000, projectable = true }, 0.1)
		local window = runtime:window()
		assert.are.equal(100, window.columns)
		assert.are.equal(100, window.rows)
		assert.are.equal("compressed", window.zoomState)
		assert.are.equal(window.startId + (window.columns * window.rows) - 1, window.endId)
		assert.is_true(window.startId >= 0)
	end)

	it("derives margin from grid size when percent configured", function()
		local runtime = Runtime.new({
			adjustInterval = 0,
			visualsTTL = 5,
			activeCellTTLFactor = 4,
		})
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
		local runtime = Runtime.new({
			adjustInterval = 0,
			margin = 5,
			activeCellTTLFactor = 4,
		})
		runtime:ingest({ type = "source", id = 10, projectionKey = 10, projectable = true }, 0)
		runtime:ingest({ type = "source", id = 20, projectionKey = 20, projectable = true }, 1)
		local window = runtime:window()
		assert.are.equal(5, window.margin)
	end)

	it("keeps a bounded per-key history for projectable events", function()
		local runtime = Runtime.new({
			historyLimit = 2,
		})
		runtime:ingest({ type = "source", id = 10, projectionKey = 10, projectable = true, schema = "A" }, 1)
		runtime:ingest({
			type = "joinresult",
			kind = "match",
			layer = 3,
			projectionKey = 10,
			projectable = true,
			left = { schema = "A", id = 10 },
			right = { schema = "B", id = 20 },
		}, 2)
		runtime:ingest({
			type = "expire",
			layer = 3,
			projectionKey = 10,
			projectable = true,
			reason = "timeout",
		}, 3)

		local history = runtime.history[10]
		assert.is_not_nil(history)
		assert.are.equal(2, #history) -- bounded at historyLimit
		assert.are.equal("joinresult", history[1].type)
		assert.are.equal("match", history[1].kind)
		-- layer is clamped to runtime.maxLayers when ingested
		assert.are.equal(2, history[1].layer)
		assert.are.equal("expire", history[2].type)
		assert.are.equal("timeout", history[2].reason)
	end)
end)
