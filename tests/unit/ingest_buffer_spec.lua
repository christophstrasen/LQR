package.path = table.concat({ package.path, "./?.lua", "./?/init.lua" }, ";")
local Ingest = require("LQR/ingest")

describe("ingest buffer (latestByKey)", function()
	it("evicts from lowest-priority lane using LRU within that lane", function()
		local buf = Ingest.buffer({
			name = "test",
			mode = "latestByKey",
			capacity = 2,
			key = function(item)
				return item.key
			end,
			lane = function(item)
				return item.lane
			end,
			lanePriority = function(laneName)
				if laneName == "high" then
					return 2
				end
				return 1
			end,
		})

		buf:ingest({ key = "k1", lane = "high" }) -- seq1
		buf:ingest({ key = "k2", lane = "low" })  -- seq2
		buf:ingest({ key = "k3", lane = "low" })  -- seq3, should evict k2

		local stats = buf:drain({ maxItems = 0 })
		assert.is.equal(0, stats.processed)
		assert.is.equal(1, stats.dropped) -- eviction
		assert.is.equal(2, stats.pending)

		local snap = buf:metrics_get()
		assert.is.equal(1, snap.totals.droppedTotal)
		assert.is.equal(2, snap.pending)
		assert.is.truthy(buf.lanes.high.pending["k1"])
		assert.is.truthy(buf.lanes.low.pending["k3"])
		assert.is_nil(buf.lanes.low.pending["k2"])
	end)

	it("counts replacements without bumping enqueuedTotal", function()
		local buf = Ingest.buffer({
			name = "replace",
			mode = "latestByKey",
			capacity = 5,
			key = function(item)
				return item.key
			end,
		})

		buf:ingest({ key = "a" })
		buf:ingest({ key = "a" })

		local snap = buf:metrics_get()
		assert.is.equal(1, snap.totals.enqueuedTotal)
		assert.is.equal(1, snap.totals.replacedTotal)

		local stats = buf:drain({ maxItems = 0 })
		assert.is.equal(1, stats.replaced)
		assert.is.equal(0, stats.processed)
	end)

	it("drains FIFO per lane when ordering=fifo", function()
		local buf = Ingest.buffer({
			name = "fifo",
			mode = "latestByKey",
			ordering = "fifo",
			capacity = 5,
			key = function(item)
				return item.key
			end,
			lane = function(item)
				return item.lane
			end,
			lanePriority = function(laneName)
				if laneName == "b" then
					return 2
				end
				return 1
			end,
		})

		buf:ingest({ key = "a1", lane = "a" })
		buf:ingest({ key = "a2", lane = "a" })
		buf:ingest({ key = "b1", lane = "b" })

		local seen = {}
		local function handle(item)
			table.insert(seen, item.key)
		end

		local stats = buf:drain({ maxItems = 3, handle = handle })
		assert.is.equal(3, stats.processed)
		-- lane b (higher priority) first, then lane a fifo
		assert.are.same({ "b1", "a1", "a2" }, seen)
	end)

	it("drops bad keys and warns via metrics", function()
		local buf = Ingest.buffer({
			name = "badkey",
			mode = "latestByKey",
			capacity = 2,
			key = function()
				return nil
			end,
		})

		buf:ingest({ any = "thing" })
		local stats = buf:drain({ maxItems = 0 })
		assert.is.equal(1, stats.dropped)
		local snap = buf:metrics_get()
		assert.is.equal(1, snap.totals.droppedTotal)
	end)

	it("metrics_reset does not clear buffered items", function()
		local buf = Ingest.buffer({
			name = "reset",
			mode = "latestByKey",
			capacity = 2,
			key = function(item)
				return item.key
			end,
		})

		buf:ingest({ key = "keep" })
		buf:metrics_reset()
		local snap = buf:metrics_get()
		assert.is.equal(1, snap.pending)
		assert.is.truthy(buf.lanes.default.pending["keep"])
	end)

	it("clear empties the buffer without wiping historical totals", function()
		local buf = Ingest.buffer({
			name = "clearable",
			mode = "latestByKey",
			capacity = 3,
			key = function(item)
				return item.key
			end,
		})

		buf:ingest({ key = "a" })
		buf:ingest({ key = "b" })
		buf:ingest({ key = "c" })

		buf:clear()

		local stats = buf:drain({ maxItems = 10, handle = function() end })
		assert.is.equal(0, stats.processed)
		assert.is.equal(0, stats.pending)

		local snap = buf:metrics_get()
		assert.is.equal(0, snap.pending)
		assert.is.equal(3, snap.totals.ingestedTotal) -- history preserved
		assert.is_nil(buf.lanes.default.pending["a"])
		assert.is_nil(buf.lanes.default.pending["b"])
		assert.is_nil(buf.lanes.default.pending["c"])
	end)
end)

describe("ingest buffer (dedupSet)", function()
	it("dedups pending keys and evicts lowest-priority lane", function()
		local buf = Ingest.buffer({
			name = "dedup",
			mode = "dedupSet",
			capacity = 2,
			key = function(item)
				return item.key
			end,
			lane = function(item)
				return item.lane
			end,
			lanePriority = function(laneName)
				if laneName == "high" then
					return 2
				end
				return 1
			end,
		})

		buf:ingest({ key = "k1", lane = "high" })
		buf:ingest({ key = "k1", lane = "high" }) -- dedup
		buf:ingest({ key = "k2", lane = "low" })
		buf:ingest({ key = "k3", lane = "low" }) -- triggers eviction of k2

		local stats = buf:drain({ maxItems = 0 })
		assert.is.equal(1, stats.dropped) -- eviction
		local snap = buf:metrics_get()
		assert.is.equal(1, snap.totals.dedupedTotal)
		assert.is.truthy(buf.lanes.high.pending["k1"])
		assert.is.truthy(buf.lanes.low.pending["k3"])
		assert.is_nil(buf.lanes.low.pending["k2"])
	end)
end)

describe("ingest buffer (queue)", function()
	it("drops oldest in lowest-priority lane on overflow", function()
		local buf = Ingest.buffer({
			name = "queue",
			mode = "queue",
			capacity = 3,
			key = function(item)
				return item.key
			end,
			lane = function(item)
				return item.lane
			end,
			lanePriority = function(laneName)
				if laneName == "hi" then
					return 2
				end
				return 1
			end,
		})

		buf:ingest({ key = "a1", lane = "hi" })
		buf:ingest({ key = "b1", lane = "lo" })
		buf:ingest({ key = "b2", lane = "lo" })
		buf:ingest({ key = "b3", lane = "lo" }) -- overflow, should drop oldest from lo (b1)

		local seen = {}
		buf:drain({
			maxItems = 3,
			handle = function(item)
				table.insert(seen, item.key)
			end,
		})

		-- hi lane drains first, then lo lane FIFO (b2, b3)
		assert.are.same({ "a1", "b2", "b3" }, seen)
		local snap = buf:metrics_get()
		assert.is.equal(1, snap.totals.droppedTotal) -- dropOldest
	end)
end)

describe("ingest buffer (hooks, budgets, metrics)", function()
	it("honors time budget and leaves remaining pending", function()
		local buf = Ingest.buffer({
			name = "time",
			mode = "latestByKey",
			capacity = 5,
			ordering = "fifo",
			key = function(item)
				return item.key
			end,
		})
		buf:ingest({ key = "a" })
		buf:ingest({ key = "b" })
		buf:ingest({ key = "c" })

		local times = { 0, 1, 3 }
		local tIndex = 0
		local function nowMillis()
			tIndex = tIndex + 1
			return times[tIndex]
		end

		local seen = {}
		local stats = buf:drain({
			maxItems = 5,
			maxMillis = 2,
			nowMillis = nowMillis,
			handle = function(item)
				table.insert(seen, item.key)
			end,
		})

		assert.is.equal(2, #seen)
		assert.is.equal(2, stats.processed)
		assert.is.equal(1, stats.pending) -- c left pending after budget hit
	end)

	it("fires hooks for drop/replace and drain lifecycle", function()
		local dropCalled, replaces, starts, ends = false, 0, 0, 0
		local buf = Ingest.buffer({
			name = "hooks",
			mode = "latestByKey",
			capacity = 3,
			key = function(item)
				return item.key
			end,
			onDrop = function()
				dropCalled = true
			end,
			onReplace = function()
				replaces = replaces + 1
			end,
			onDrainStart = function()
				starts = starts + 1
			end,
			onDrainEnd = function()
				ends = ends + 1
			end,
		})

		buf:ingest({ key = nil }) -- badKey drop
		assert.is_true(dropCalled)
		buf:ingest({ key = "x" })
		buf:ingest({ key = "x" }) -- replace

		local stats = buf:drain({ maxItems = 1, handle = function() end })

		assert.is_true(dropCalled)
		assert.is.equal(1, replaces)
		assert.is.equal(1, starts)
		assert.is.equal(1, ends)
		assert.is.equal(1, stats.processed)
	end)

	it("reports per-lane metrics after drain", function()
		local buf = Ingest.buffer({
			name = "metrics",
			mode = "dedupSet",
			capacity = 4,
			ordering = "fifo",
			key = function(item)
				return item.key
			end,
			lane = function(item)
				return item.lane
			end,
		})

		buf:ingest({ key = "a1", lane = "A" }) -- seq1
		buf:ingest({ key = "a1", lane = "A" }) -- dedup
		buf:ingest({ key = "b1", lane = "B" }) -- seq3
		buf:ingest({ key = "b2", lane = "B" }) -- seq4

		buf:drain({ maxItems = 2, handle = function() end })
		local snap = buf:metrics_get()

		assert.is.equal(1, snap.totals.dedupedTotal)
		assert.is_true((snap.perLane["A"] or {}).pending >= 0)
		assert.is_true((snap.perLane["B"] or {}).pending >= 0)
	assert.is.equal(2, snap.totals.drainedTotal)
	-- seqSpan should reflect remaining items (non-negative number)
	assert.is_true(snap.ingestSeqSpan >= 0)
	-- pending counts should match total pending
	local lanePending = ((snap.perLane["A"] or {}).pending or 0) + ((snap.perLane["B"] or {}).pending or 0)
	assert.is.equal(snap.pending, lanePending)
end)

describe("ingest buffer (load averages)", function()
	it("maintains load-style EWMAs for pending and throughput", function()
		local t = 0
		local function nowMillis()
			return t
		end

		local buf = Ingest.buffer({
			name = "load",
			mode = "latestByKey",
			capacity = 5,
			key = function(item)
				return item.key
			end,
		})

		buf:ingest({ key = "a" })
		buf:ingest({ key = "b" })

		-- Seed load with pending backlog (no work drained).
		buf:drain({ maxItems = 0, nowMillis = nowMillis })
		local snap1 = buf:metrics_get()
		assert.is.equal(2, snap1.load1)
		assert.is.equal(0, snap1.throughput1)

		-- Advance 1s, drain one item.
		t = 1000
		buf:drain({ maxItems = 1, nowMillis = nowMillis, handle = function() end })
		local snap2 = buf:metrics_get()

		-- load1 should be between pendingAfter (1) and previous (2); throughput ~1 item/sec.
		assert.is_true(snap2.load1 > 1 and snap2.load1 < 2.1)
		assert.is_true(math.abs(snap2.throughput1 - 0.63) < 0.05)
	end)

	it("offers advice including recommended maxItems", function()
		local t = 0
		local function nowMillis()
			return t
		end

		local buf = Ingest.buffer({
			name = "advice",
			mode = "latestByKey",
			capacity = 5,
			key = function(it)
				return it.key
			end,
		})

		buf:ingest({ key = "a" })
		buf:ingest({ key = "b" })
		buf:drain({ maxItems = 0, nowMillis = nowMillis })

		-- advance 1s, ingest and drain one
		t = 1000
		buf:ingest({ key = "c" })
		buf:drain({ maxItems = 1, nowMillis = nowMillis, handle = function() end })

		local advice = buf:advice_get({ targetClearSeconds = 5 })
		assert.is_true(advice.recommendedMaxItems ~= nil)
		assert.is_true(advice.recommendedMaxItems >= 1)
		assert.is_true(type(advice.trend) == "string")
	end)

	it("smooths/clamps budgets via advice_applyMaxItems", function()
		local t = 0
		local function nowMillis()
			return t
		end

		local buf = Ingest.buffer({
			name = "advice2",
			mode = "latestByKey",
			capacity = 10,
			key = function(it) return it.key end,
		})

		for i = 1, 5 do
			buf:ingest({ key = "k" .. i })
		end

		buf:drain({ maxItems = 0, nowMillis = nowMillis }) -- seed load/ingest
		t = 1000
		buf:drain({ maxItems = 2, nowMillis = nowMillis, handle = function() end })

		local current = 5
		local newMax, advice = buf:advice_applyMaxItems(current, {
			alpha = 0.5,
			minItems = 1,
			maxItems = 10,
		})

		assert.is_true(newMax >= 1 and newMax <= 10)
		assert.is_true(type(advice.trend) == "string")
	end)

	it("warns and no-ops advice_applyMaxMillis when timing is insufficient", function()
		local buf = Ingest.buffer({
			name = "advice3",
			mode = "latestByKey",
			capacity = 5,
			key = function(it) return it.key end,
		})
		buf:ingest({ key = "a" })
		-- No nowMillis/spentMillis ever observed
		local newMax, advice = buf:advice_applyMaxMillis(100, {})
		assert.is.equal(100, newMax)
		assert.is_true(type(advice.trend) == "string")
	end)
end)
end)
