local package = require("package")
package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require("bootstrap")

local PreRender = require("viz.pre_render")

local function closeEnough(a, b, eps)
	eps = eps or 1e-6
	return math.abs(a - b) <= eps
end

describe("PreRender State color mixing", function()
	it("blends existing color according to remaining alpha weight", function()
		local palette = {
			foo = { 0.6, 0.2, 0.1, 1 },
			bar = { 0.0, 1.0, 0.0, 1 },
		}
		local state = PreRender.State.new({
			columns = 1,
			rows = 1,
			palette = palette,
		})

		state:ingest(101, "foo")
		local entry = state.entries[101]
		entry.color = { 0.5, 0.3, 0.1, 1 }
		entry.alpha = 10 -- simulate heavy fading but not zero

		state:ingest(101, "bar")
		local mixed = state.entries[101].color

		-- existing weight should be 0.1 (alpha / 100)
		assert.is_true(closeEnough(mixed[1], 0.5 * 0.1 + 0.0 * 0.9))
		assert.is_true(closeEnough(mixed[2], 0.3 * 0.1 + 1.0 * 0.9))
		assert.is_true(closeEnough(mixed[3], 0.1 * 0.1 + 0.0 * 0.9))
	end)

	it("lets the new color dominate when the entry alpha reached zero", function()
		local palette = {
			foo = { 1.0, 0.0, 0.0, 1 },
			bar = { 0.0, 1.0, 0.0, 1 },
		}
		local state = PreRender.State.new({
			columns = 1,
			rows = 1,
			palette = palette,
		})

		state:ingest(202, "foo")
		local entry = state.entries[202]
		entry.color = { 0.2, 0.2, 0.2, 1 }
		entry.alpha = 0

		state:ingest(202, "bar")
		local color = state.entries[202].color

		assert.is_true(closeEnough(color[1], palette.bar[1]))
		assert.is_true(closeEnough(color[2], palette.bar[2]))
		assert.is_true(closeEnough(color[3], palette.bar[3]))
	end)
end)
