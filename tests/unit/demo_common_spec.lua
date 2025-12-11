local package = require("package")
package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require('LQR/bootstrap')

local ZonesTimeline = require("vizualisation/demo/common/zones_timeline")
local Driver = require("vizualisation/demo/common/driver")

---@diagnostic disable: undefined-global
describe("demo common helpers", function()
	it("builds timeline events from zones and appends a completion marker", function()
		local events, snaps = ZonesTimeline.build({
			{
				label = "a",
				schema = "customers",
				center = 1,
				range = 0,
				shape = "continuous",
				density = 1,
				t0 = 0,
				t1 = 0.1,
				rate_shape = "constant",
			},
		}, {
			totalPlaybackTime = 4,
			playStart = 0,
			completeDelay = 0.2,
		})

		assert.is_true(#events >= 2) -- one emit + completion
		assert.are.same("complete", events[#events].kind)
		assert.is_true(#snaps >= 1)
	end)

	it("drives scheduler events into subjects via driver helper", function()
		local received = {}
		local subjects = {
			customers = {
				onNext = function(_, payload)
					received[#received + 1] = payload
				end,
				onCompleted = function(_) end,
			},
		}
		local driver = Driver.new({
			events = {
				{ tick = 0, schema = "customers", payload = { id = 1 } },
				{ tick = 1, kind = "complete" },
			},
			subjects = subjects,
			ticksPerSecond = 10,
			label = "test",
		})

		driver:runAll()
		assert.are.same(1, #received)
		assert.are.same(1, received[1].id)
	end)
end)
