local package = require("package")
package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require("bootstrap")

local Runtime = require("viz_high_level.runtime")

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
		assert.are.equal(55, window.endId)

		runtime:ingest({ type = "source", id = 80 }, 2.7) -- within hysteresis window, no change
		window = runtime:window()
		assert.are.equal(50, window.startId)
		assert.are.equal(55, window.endId)

		runtime:ingest({ type = "source", id = 90 }, 5) -- adjust again, clamp span to 10
		window = runtime:window()
		assert.are.equal(81, window.startId)
		assert.are.equal(90, window.endId)
	end)

	it("clamps match/expire layers to maxLayers", function()
		local runtime = Runtime.new({ maxLayers = 5 })
		runtime:ingest({ type = "match", layer = 10 })
		runtime:ingest({ type = "expire", layer = 0 })

		assert.are.equal(1, #runtime.events.match)
		assert.are.equal(5, runtime.events.match[1].layer)
		assert.are.equal(1, #runtime.events.expire)
		assert.are.equal(1, runtime.events.expire[1].layer)
	end)
end)
