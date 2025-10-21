local package = require("package")
package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require("bootstrap")

local CellLayers = require("viz_high_level.core.cell_layers")

---@diagnostic disable: undefined-global
describe("cell_layers helper", function()
	it("blends layers over TTL and removes expired ones", function()
		local layer = CellLayers.CellLayer.new({ 0, 0, 0, 1 }, 1)
		layer:addLayer({ color = { 1, 0, 0, 1 }, ts = 0, ttl = 1, id = "red" })

		layer:update(0)
		local colorZero = select(1, layer:getColor())
		assert.is_true(colorZero[1] > 0.9)

		layer:update(0.5)
		local colorMid = select(1, layer:getColor())
		assert.is_true(colorMid[1] > 0.4 and colorMid[1] < 0.6)

		layer:update(1.1)
		local colorEnd = select(1, layer:getColor())
		assert.is_true(colorEnd[1] < 0.1)
	end)

	it("composes composite cell regions and handles TTL per border", function()
		local composite = CellLayers.CompositeCell.new({
			ttl = 1,
			maxLayers = 2,
			innerColor = { 0.2, 0.2, 0.2, 1 },
			borderColor = { 0.24, 0.24, 0.24, 1 },
			gapColor = { 0.12, 0.12, 0.12, 1 },
		})

		local inner = composite:getInner()
		inner:addLayer({ color = { 0, 1, 0, 1 }, ts = 0, ttl = 1, id = "inner" })
		local border1 = composite:getBorder(1)
		border1:addLayer({ color = { 1, 0, 0, 1 }, ts = 0, ttl = 1, id = "border1" })

		composite:update(0.11)
		local innerColor = select(1, inner:getColor())
		local borderColor = select(1, border1:getColor())
		assert.is_true(innerColor[2] > 0.5)
		assert.is_true(borderColor[1] > 0.8)

		composite:update(0.7)
		local fadedInner = select(1, inner:getColor())
		local fadedBorder = select(1, border1:getColor())
		assert.is_true(fadedInner[2] < innerColor[2])
		assert.is_true(fadedBorder[1] < borderColor[1])

		composite:update(1.4)
		local finalInner = select(1, inner:getColor())
		local finalBorder = select(1, border1:getColor())
		assert.is_true(finalInner[2] <= 0.21)
		assert.is_true(finalBorder[1] <= 0.25)
	end)
end)
