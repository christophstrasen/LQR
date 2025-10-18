local package = require("package")
package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require("bootstrap")

local Runtime = require("viz_high_level.runtime")
local Renderer = require("viz_high_level.headless_renderer")

---@diagnostic disable: undefined-global
describe("viz_high_level headless renderer", function()
	it("maps inner and layered borders to grid cells", function()
		local palette = {
			customers = { 0.1, 0.2, 0.3, 1 },
			joined = { 0, 1, 0, 1 },
			expired = { 1, 0, 0, 1 },
		}
		local runtime = Runtime.new({
			maxLayers = 5,
			maxColumns = 5,
			maxRows = 2,
			startId = 10,
			adjustInterval = 0,
		})

		runtime:ingest({ type = "source", schema = "customers", id = 10 })
		runtime:ingest({ type = "match", layer = 1, key = 10, left = { id = 10 } })
		runtime:ingest({ type = "expire", layer = 2, id = 14, reason = "evicted" })

		local snap = Renderer.render(runtime, palette)
		assert.are.same(10, snap.window.startId)
		assert.are.same(19, snap.window.endId)

		local innerCell = snap.cells[1][1]
		assert.are.same("customers", innerCell.inner.schema)
		assert.are.same(palette.customers, innerCell.inner.color)

		local matchBorder = innerCell.borders[1]
		assert.are.same("match", matchBorder.kind)
		assert.are.same(palette.joined, matchBorder.color)

		local expireCol, expireRow = 5, 1 -- id 14 maps to index 5
		local expireCell = snap.cells[expireCol][expireRow]
		assert.are.same("expire", expireCell.borders[2].kind)
		assert.are.same("evicted", expireCell.borders[2].reason)
		assert.are.same(palette.expired, expireCell.borders[2].color)
	end)
end)
