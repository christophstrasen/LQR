local package = require("package")
package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require("bootstrap")

local ShapeWeights = require("viz_high_level.zones.shape_weights")
local Generator = require("viz_high_level.zones.generator")

---@diagnostic disable: undefined-global
describe("zone generator", function()
	it("builds simple flat weights centered on an id", function()
		local weights = ShapeWeights.build({
			center = 10,
			radius = 2,
			shape = "flat",
		})

		local ids = {}
		for _, entry in ipairs(weights) do
			ids[#ids + 1] = { id = entry.id, weight = entry.weight }
		end

		assert.are.same({
			{ id = 8, weight = 1 },
			{ id = 9, weight = 1 },
			{ id = 10, weight = 1 },
			{ id = 11, weight = 1 },
			{ id = 12, weight = 1 },
		}, ids)
	end)

	it("uses density and rate shapes to emit deterministic events", function()
		local events, summary = Generator.generate({
			{
				label = "a",
				schema = "customers",
				center = 10,
				radius = 2,
				shape = "flat",
				density = 0.5, -- selects 3 of 5 ids: 8,9,10
				t0 = 0,
				t1 = 1,
				rate_shape = "linear_up",
			},
		}, {
			totalPlaybackTime = 10,
			playStart = 0,
		})

		assert.are.equal(3, #events)
		assert.are.same({ 8, 9, 10 }, { events[1].payload.id, events[2].payload.id, events[3].payload.id })
		-- Rate weights 1,2,3 over span -> ticks ~ 1.67, 5.00, 10.00
		assert.is_true(events[1].tick < events[2].tick)
		assert.is_true(events[2].tick < events[3].tick)

		assert.are.same(3, summary.total)
		assert.are.same(3, summary.schemas.customers.count)
		assert.are.same({ a = 3 }, summary.schemas.customers.perZone)
	end)

	it("emits warnings on duplicate schema/id/tick combinations", function()
		local events, summary = Generator.generate({
			{
				label = "z1",
				schema = "orders",
				center = 5,
				radius = 0,
				shape = "flat",
				density = 1,
				t0 = 0.2,
				t1 = 0.3,
				rate_shape = "constant",
			},
			{
				label = "z2",
				schema = "orders",
				center = 5,
				radius = 0,
				shape = "flat",
				density = 1,
				t0 = 0.2,
				t1 = 0.3,
				rate_shape = "constant",
			},
		}, {
			totalPlaybackTime = 10,
			playStart = 0,
		})

		assert.are.equal(2, #events)
		assert.are.same("orders", events[1].schema)
		assert.are.same("orders", events[2].schema)
		assert.is_true(#summary.warnings >= 1)
	end)
end)
