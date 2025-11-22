local package = require("package")
package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require("bootstrap")

local Runtime = require("vizualisation.core.runtime")
local Renderer = require("vizualisation.core.headless_renderer")

---@diagnostic disable: undefined-global
describe("vizualisation headless renderer TTL factors", function()
	it("applies per-kind and per-layer TTL scaling", function()
		local baseTTL = 2
		local factors = {
			source = 0.5,
			joined = 1.5,
			expire = 0.25,
		}
		local layerFactors = {
			[1] = 1.0,
			[2] = 2.0, -- amplify outer layer
		}

		local runtime = Runtime.new({
			maxLayers = 2,
			maxColumns = 1,
			maxRows = 1,
			startId = 0,
			visualsTTL = baseTTL,
			visualsTTLFactors = factors,
			visualsTTLLayerFactors = layerFactors,
			header = {},
		})

		runtime.events = {
			source = {
				{
					schema = "customers",
					id = 0,
					projectionKey = 0,
					projectable = true,
					ingestTime = 0,
				},
			},
			match = {
				{
					layer = 2,
					projectable = true,
					projectionKey = 0,
					ingestTime = 0,
				},
			},
			expire = {
				{
					layer = 1,
					projectable = true,
					projectionKey = 0,
					ingestTime = 0,
				},
			},
		}

		local snap = Renderer.render(runtime, {}, 0)
		local cell = snap.cells[1] and snap.cells[1][1]
		assert.is_not_nil(cell)

		local inner = cell.composite:getInner()
		local innerLayerTTL = inner.layers[next(inner.layers)].ttl
		assert.are.equal(baseTTL * factors.source, innerLayerTTL)

		local matchBorder = cell.composite:getBorder(2)
		local matchLayerTTL = matchBorder.layers[next(matchBorder.layers)].ttl
		assert.are.equal(baseTTL * factors.joined * layerFactors[2], matchLayerTTL)

		local expireBorder = cell.composite:getBorder(1)
		local expireLayerTTL = expireBorder.layers[next(expireBorder.layers)].ttl
		assert.are.equal(baseTTL * factors.expire, expireLayerTTL)
	end)
end)
