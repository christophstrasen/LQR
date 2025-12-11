local package = require("package")
package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require('LQR/bootstrap')

local ShapeWeights = require("vizualisation/zones/shape_weights")
local Generator = require("vizualisation/zones/generator")

---@diagnostic disable: undefined-global
describe("zone generator", function()
	it("builds simple flat weights centered on an id", function()
		local weights = ShapeWeights.build({
			center = 10,
			range = 2,
			shape = "continuous",
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

	it("uses coverage and rate shapes to emit deterministic events without slowing rate", function()
		local events, summary = Generator.generate({
			{
				label = "a",
				schema = "customers",
				center = 10,
				range = 2,
				shape = "continuous",
				density = 0.5, -- selects 3 of 5 ids but keeps rate based on the full span
				t0 = 0,
				t1 = 1,
				rate_shape = "linear_up",
				mode = "monotonic",
			},
		}, {
			totalPlaybackTime = 10,
			playStart = 0,
		})

		-- Coverage thins spatial ids but rate still drives total events (repeats allowed).
		assert.are.equal(5, #events)
		for i = 1, #events do
			assert.is_true(events[i].payload.id >= 8 and events[i].payload.id <= 12)
		end
		-- Coverage thins spatial ids but keeps uniform spacing in time.
		-- Rate weights 1..5 over span -> ticks strictly increasing
		assert.is_true(events[1].tick < events[2].tick)
		assert.is_true(events[2].tick < events[3].tick)
		assert.is_true(events[3].tick < events[4].tick)
		assert.is_true(events[4].tick < events[5].tick)

		assert.are.same(5, summary.total)
		assert.are.same(5, summary.schemas.customers.count)
		assert.are.same({ a = 5 }, summary.schemas.customers.perZone)
		assert.are.same("linear", summary.mappingHint)
	end)

	it("warns and defaults range for circle when missing", function()
		local events, summary = Generator.generate({
			{
				label = "circle_no_range",
				schema = "customers",
				center = 0,
				shape = "circle10",
				density = 0.2,
				t0 = 0,
				t1 = 0.1,
				rate_shape = "constant",
			},
		}, {
			totalPlaybackTime = 1,
			playStart = 0,
			grid = { startId = 0, columns = 10, rows = 10 },
		})

		assert.is_true(#events > 0)
		assert.is_true(#summary.warnings >= 1)
		assert.are.same("spiral", summary.mappingHint)
	end)

	it("emits warnings on duplicate schema/id/tick combinations", function()
		local events, summary = Generator.generate({
			{
				label = "z1",
				schema = "orders",
				center = 5,
				range = 0,
				shape = "continuous",
				density = 1,
				t0 = 0.2,
				t1 = 0.3,
				rate_shape = "constant",
			},
			{
				label = "z2",
				schema = "orders",
				center = 5,
				range = 0,
				shape = "continuous",
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
