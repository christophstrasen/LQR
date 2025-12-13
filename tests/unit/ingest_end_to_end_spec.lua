package.path = table.concat({ package.path, "./?.lua", "./?/init.lua" }, ";")
local Ingest = require("LQR/ingest")
local Query = require("LQR/Query")
local SchemaHelpers = require("tests/support/schema_helpers")

local function collect(observable)
	local out = {}
	observable:subscribe(function(value)
		out[#out + 1] = value
	end)
	return out
end

describe("ingest end-to-end", function()
	it("drains two lanes by priority across ticks", function()
		local handled = {}
		local buf = Ingest.buffer({
			name = "e2e",
			mode = "latestByKey",
			ordering = "fifo",
			capacity = 4,
			key = function(it)
				return it.key
			end,
			lane = function(it)
				return it.lane
			end,
			lanePriority = function(lane)
				return lane == "hi" and 2 or 1
			end,
		})

		local function emitHi(k)
			buf:ingest({ key = k, lane = "hi" })
		end
		local function emitLo(k)
			buf:ingest({ key = k, lane = "lo" })
		end

		-- Two sources emit in the same "tick" (burst).
		emitHi("h1")
		emitLo("l1")
		emitLo("l2")
		emitHi("h2")

		-- Tick 1: global budget only allows two items.
		local stats1 = buf:drain({
			maxItems = 2,
			handle = function(item)
				table.insert(handled, item.key)
			end,
		})

		assert.are.same({ "h1", "h2" }, handled) -- priority lane first, FIFO within lane
		assert.is.equal(2, stats1.processed)
		assert.is.equal(2, stats1.pending) -- l1, l2 remain

		-- Tick 2: drain the rest.
		local stats2 = buf:drain({
			maxItems = 10,
			handle = function(item)
				table.insert(handled, item.key)
			end,
		})

		assert.is.equal(2, stats2.processed)
		assert.are.same({ "h1", "h2", "l1", "l2" }, handled)

		local m = buf:metrics_get()
		assert.is.equal(4, m.totals.ingestedTotal)
		assert.is.equal(4, m.totals.drainedTotal)
		assert.is.equal(0, m.pending)
	end)

	it("drops oldest in queue mode and fires onDrop hook", function()
		local drops = {}
		local buf = Ingest.buffer({
			name = "queue-e2e",
			mode = "queue",
			capacity = 3,
			key = function(it)
				return it.key
			end,
			lane = function(it)
				return it.lane
			end,
			lanePriority = function(lane)
				return lane == "prio" and 2 or 1
			end,
			onDrop = function(info)
				table.insert(drops, info and info.key or "unknown")
			end,
		})

		-- Fill with low-priority events first.
		buf:ingest({ key = "lo1", lane = "lo" })
		buf:ingest({ key = "lo2", lane = "lo" })
		-- Add higher-priority item then overflow with another low → oldest low should drop.
		buf:ingest({ key = "hi1", lane = "prio" })
		buf:ingest({ key = "lo3", lane = "lo" })

		local handled = {}
		buf:drain({
			maxItems = 10,
			handle = function(item)
				table.insert(handled, item.key)
			end,
		})

		-- hi lane drains first, then remaining low FIFO (lo2, lo3)
		assert.are.same({ "hi1", "lo2", "lo3" }, handled)
		assert.are.same({ "lo1" }, drops) -- lo1 was oldest in losing lane
	end)

	it("respects time budget mid-queue with a monotonic clock", function()
		local buf = Ingest.buffer({
			name = "time-budget",
			mode = "queue",
			capacity = 5,
			key = function(it)
				return it.key
			end,
		})

		for i = 1, 4 do
			buf:ingest({ key = "k" .. i })
		end

		local ticks = { 0, 1, 3 } -- drain will stop once spentMillis >= 2
		local t = 0
		local function nowMillis()
			t = t + 1
			return ticks[t]
		end

		local handled = {}
		local stats = buf:drain({
			maxItems = 10,
			maxMillis = 2,
			nowMillis = nowMillis,
			handle = function(item)
				table.insert(handled, item.key)
			end,
		})

		assert.are.same({ "k1", "k2" }, handled)
		assert.is.equal(2, stats.processed)
		assert.is.equal(2, stats.pending) -- k3, k4 remain
	end)

	it("drains two buffers via scheduler priority and aggregates metrics", function()
		local bufA = Ingest.buffer({
			name = "A",
			mode = "latestByKey",
			capacity = 5,
			key = function(it)
				return it.key
			end,
		})
		local bufB = Ingest.buffer({
			name = "B",
			mode = "queue",
			capacity = 5,
			key = function(it)
				return it.key
			end,
		})

		bufA:ingest({ key = "a1" })
		bufB:ingest({ key = "b1" })
		bufB:ingest({ key = "b2" })

		local sched = Ingest.scheduler({
			name = "sched-e2e",
			maxItemsPerTick = 2,
		})
		sched:addBuffer(bufA, { priority = 1 })
		sched:addBuffer(bufB, { priority = 2 }) -- higher priority drains first

		local seen = {}
		local stats = sched:drainTick(function(item)
			table.insert(seen, item.key)
		end)

		assert.are.same({ "b1", "b2" }, seen)
		assert.is.equal(2, stats.processed)
		assert.is.equal(1, bufA:metrics_get().pending)

		local m = sched:metrics_get()
		assert.is.equal(2, m.drainedTotal)
		assert.is.truthy(m.buffers["A"])
		assert.is.truthy(m.buffers["B"])
	end)

	it("feeds buffer output into a LQR query end-to-end", function()
		-- Buffer collects latest-by-key, then drains into a schema + Query pipeline.
		local subject, observable = SchemaHelpers.subjectWithSchema("items", { idField = "id" })
		local results = collect(Query.selectFrom(observable, "items"))

		local buf = Ingest.buffer({
			name = "into-query",
			mode = "latestByKey",
			capacity = 5,
			ordering = "fifo",
			key = function(it)
				return it.key
			end,
		})

		buf:ingest({ key = "k1", id = 1, value = 10 })
		buf:ingest({ key = "k1", id = 1, value = 20 }) -- replacement
		buf:ingest({ key = "k2", id = 2, value = 30 })

		buf:drain({
			maxItems = 10,
			handle = function(item)
				subject:onNext(item)
			end,
		})
		subject:onCompleted()

		-- Query delivers the latest payload per key through Schema.wrap.
		local values = {}
		for _, row in ipairs(results) do
			table.insert(values, row.items.value)
		end
		table.sort(values)

		assert.are.same({ 20, 30 }, values)
		assert.is.equal(2, #results)
	end)
end)
