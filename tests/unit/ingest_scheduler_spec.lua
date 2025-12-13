package.path = table.concat({ package.path, "./?.lua", "./?/init.lua" }, ";")
local Ingest = require("LQR/ingest")

describe("ingest scheduler", function()
	it("drains buffers by priority under global budget", function()
		local bufA = Ingest.buffer({
			name = "A",
			mode = "latestByKey",
			capacity = 5,
			key = function(item)
				return item.key
			end,
		})
		local bufB = Ingest.buffer({
			name = "B",
			mode = "latestByKey",
			capacity = 5,
			ordering = "fifo",
			key = function(item)
				return item.key
			end,
		})

		bufA:ingest({ key = "a1" })
		bufB:ingest({ key = "b1" })
		bufB:ingest({ key = "b2" })

		local sched = Ingest.scheduler({
			name = "sched",
			maxItemsPerTick = 2,
		})
		sched:addBuffer(bufA, { priority = 1 })
		sched:addBuffer(bufB, { priority = 2 })

		local seen = {}
		local stats = sched:drainTick(function(item)
			table.insert(seen, item.key)
		end)

		assert.is.equal(2, stats.processed)
		assert.are.same({ "b1", "b2" }, seen)
		-- a1 should remain pending
		local snap = bufA:metrics_get()
		assert.is.equal(1, snap.pending)
	end)

	it("aggregates metrics and resets them", function()
		local bufA = Ingest.buffer({
			name = "A",
			mode = "latestByKey",
			capacity = 5,
			key = function(item)
				return item.key
			end,
		})
		bufA:ingest({ key = "a1" })
		bufA:drain({ maxItems = 1, handle = function() end })

		local sched = Ingest.scheduler({
			name = "sched2",
			maxItemsPerTick = 1,
		})
		sched:addBuffer(bufA, { priority = 1 })

		local metrics = sched:metrics_get()
		assert.is.truthy(metrics.buffers["A"])
		assert.is.equal(1, metrics.buffers["A"].totals.drainedTotal)

		sched:metrics_reset()
		local metrics2 = sched:metrics_get()
		assert.is.equal(0, metrics2.drainedTotal)
		assert.is.equal(0, metrics2.buffers["A"].totals.drainedTotal)
	end)
end)
