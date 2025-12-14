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

	it("round-robins among buffers with the same priority", function()
		local bufA = Ingest.buffer({
			name = "A",
			mode = "latestByKey",
			capacity = 10,
			ordering = "fifo",
			key = function(item)
				return item.key
			end,
		})
		local bufB = Ingest.buffer({
			name = "B",
			mode = "latestByKey",
			capacity = 10,
			ordering = "fifo",
			key = function(item)
				return item.key
			end,
		})

		-- Both buffers have work; same priority means they should share the tick budget fairly.
		bufA:ingest({ key = "a1" })
		bufA:ingest({ key = "a2" })
		bufB:ingest({ key = "b1" })
		bufB:ingest({ key = "b2" })

		local sched = Ingest.scheduler({
			name = "sched_rr",
			maxItemsPerTick = 3,
			quantum = 1, -- strict RR: one item per buffer turn
		})
		sched:addBuffer(bufA, { priority = 2 })
		sched:addBuffer(bufB, { priority = 2 })

		local seen = {}
		local stats = sched:drainTick(function(item)
			table.insert(seen, item.key)
		end)

		assert.is.equal(3, stats.processed)
		-- Deterministic RR starts with the first-added buffer (A).
		assert.are.same({ "a1", "b1", "a2" }, seen)
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

	it("respects a maxMillisPerTick budget when nowMillis is provided", function()
		-- Fake buffer that consumes time when draining.
		local fake = {
			name = "fake",
			drainCalls = 0,
			drain = function(self, opts)
				self.drainCalls = self.drainCalls + 1
				return {
					processed = opts.maxItems or 0,
					spentMillis = 10, -- pretend this drain cost the full 10ms budget
					pending = 0,
					dropped = 0,
					replaced = 0,
				}
			end,
			metrics_get = function()
				return { pending = 0, totals = { droppedTotal = 0, replacedTotal = 0, drainedTotal = 0 } }
			end,
			metrics_reset = function() end,
		}

		local sched = Ingest.scheduler({
			name = "sched_ms",
			maxItemsPerTick = 10,
			maxMillisPerTick = 10,
			quantum = 5,
		})
		sched:addBuffer(fake, { priority = 1 })

		local now = 0
		local function nowMillis()
			now = now + 5
			return now
		end

			local stats = sched:drainTick(function() end, { nowMillis = nowMillis })
			-- First drain consumes the entire 10ms budget; second would exceed, so only one drain should run.
			assert.is.equal(1, fake.drainCalls)
			assert.is.equal(5, stats.processed) -- maxItems bounded by quantum=5 for the single call
			assert.is.equal(10, stats.spentMillis)
		end)
	end)
