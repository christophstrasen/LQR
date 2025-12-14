local Log = require("LQR/util/log").withTag("ingest.buffer")
local Metrics = require("LQR/ingest/metrics")
local Reasons = require("LQR/ingest/reasons")

local Buffer = {}
Buffer.__index = Buffer

local function isHeadless()
	-- Heuristic: treat busted runs as headless to keep tests noise-free.
	if _G.LQR_HEADLESS == true then
		return true
	end
	-- In PZ, Events exists. In vanilla/headless runtimes (including busted) it usually does not.
	if type(_G.Events) ~= "table" then
		return true
	end
	return false
end

--- @class LQRIngestBufferOpts
--- @field name string
--- @field mode "dedupSet"|"latestByKey"|"queue"
--- @field capacity integer
--- @field key fun(item:any):string|number|nil
--- @field lane fun(item:any):string|nil
--- @field lanePriority fun(laneName:string):integer
--- @field ordering "none"|"fifo"
--- @field onDrainStart fun(info:table)|nil
--- @field onDrainEnd fun(info:table)|nil
--- @field onDrop fun(info:table)|nil
--- @field onReplace fun(info:table)|nil

--- @class LQRIngestBuffer
--- @field name string
--- @field mode string
--- @field capacity integer
--- @field ingest fun(self:LQRIngestBuffer, item:any)
--- @field drain fun(self:LQRIngestBuffer, opts:table):table
--- @field metrics_get fun(self:LQRIngestBuffer):table
--- @field metrics_reset fun(self:LQRIngestBuffer)
--- @field clear fun(self:LQRIngestBuffer)
--- @field advice_get fun(self:LQRIngestBuffer, opts:table):table
--- @field advice_applyMaxItems fun(self:LQRIngestBuffer, current:number|nil, opts:table|nil):(number, table)
--- @field advice_applyMaxMillis fun(self:LQRIngestBuffer, current:number|nil, opts:table|nil):(number, table)

local function defaultLane(item)
	return "default"
end

local function defaultLanePriority()
	return 1
end

local function newLaneState(priority, ordering)
	return {
		priority = priority or 1,
		pending = {},
		lastSeen = {},
		pendingCount = 0,
		-- Min-heap of { seq, key } for eviction without scanning lastSeen.
		-- Uses lazy deletion: stale nodes are skipped when popped.
		lruHeap = {},
		-- FIFO bookkeeping
		fifo = {},
		fifoHead = 1,
		inFifo = {},
		-- Queue bookkeeping (queue mode)
		queue = {},
		queueHead = 1,
		queueTail = 0,
	}
end

local function pushFifo(lane, key)
	lane.fifo[#lane.fifo + 1] = key
	lane.inFifo[key] = true
end

local function removeFromFifo(lane, key)
	if lane.inFifo[key] then
		lane.inFifo[key] = nil
	end
end

local function popFifo(lane)
	local head = lane.fifoHead
	while head <= #lane.fifo do
		local key = lane.fifo[head]
		if key and lane.pending[key] then
			lane.fifoHead = head + 1
			lane.inFifo[key] = nil
			return key, lane.pending[key]
		end
		head = head + 1
	end
	lane.fifoHead = head
	return nil, nil
end

local function anyPending(lane)
	for k, v in pairs(lane.pending) do
		return k, v
	end
	return nil, nil
end

local function findOldestKeyBySeq(lane)
	local oldestKey
	local oldestSeq
	for key, seq in pairs(lane.lastSeen) do
		if oldestSeq == nil or seq < oldestSeq then
			oldestSeq = seq
			oldestKey = key
		end
	end
	return oldestKey
end

local function heapSwap(heap, i, j)
	heap[i], heap[j] = heap[j], heap[i]
end

local function heapLess(a, b)
	return a.seq < b.seq
end

local function heapPush(heap, node)
	heap[#heap + 1] = node
	local idx = #heap
	while idx > 1 do
		local parent = math.floor(idx / 2)
		if heapLess(heap[idx], heap[parent]) then
			heapSwap(heap, idx, parent)
			idx = parent
		else
			break
		end
	end
end

local function heapPop(heap)
	local n = #heap
	if n == 0 then
		return nil
	end
	local root = heap[1]
	local last = heap[n]
	heap[n] = nil
	n = n - 1
	if n > 0 then
		heap[1] = last
		local idx = 1
		while true do
			local left = idx * 2
			local right = left + 1
			if left > n then
				break
			end
			local smallest = left
			if right <= n and heapLess(heap[right], heap[left]) then
				smallest = right
			end
			if heapLess(heap[smallest], heap[idx]) then
				heapSwap(heap, idx, smallest)
				idx = smallest
			else
				break
			end
		end
	end
	return root
end

local function laneRebuildHeap(lane)
	lane.lruHeap = {}
	for key, seq in pairs(lane.lastSeen or {}) do
		if type(seq) == "number" then
			heapPush(lane.lruHeap, { seq = seq, key = key })
		end
	end
end

local function laneMaybeRebuildHeap(lane)
	local pending = lane.pendingCount or 0
	local heapSize = lane.lruHeap and #lane.lruHeap or 0
	if pending > 0 and heapSize > (pending * 4 + 64) then
		laneRebuildHeap(lane)
	end
end

local function lanePopOldestKey(lane)
	laneMaybeRebuildHeap(lane)
	while lane.lruHeap and #lane.lruHeap > 0 do
		local node = heapPop(lane.lruHeap)
		if node and node.key ~= nil then
			local currentSeq = lane.lastSeen[node.key]
			if currentSeq ~= nil and currentSeq == node.seq and lane.pending[node.key] ~= nil then
				return node.key
			end
		end
	end
	return nil
end

local function validateOpts(opts)
	assert(type(opts) == "table", "opts table required")
	assert(type(opts.name) == "string" and opts.name ~= "", "name is required")
	assert(type(opts.mode) == "string", "mode is required")
	assert(
		opts.mode == "dedupSet" or opts.mode == "latestByKey" or opts.mode == "queue",
		"mode must be dedupSet|latestByKey|queue"
	)
	assert(type(opts.capacity) == "number" and opts.capacity >= 1, "capacity >= 1 required")
	assert(type(opts.key) == "function", "key function required")
	if opts.ordering ~= nil then
		assert(opts.ordering == "none" or opts.ordering == "fifo", "ordering must be none|fifo when provided")
	end
end

local function normalizePriority(pri, laneName)
	if type(pri) ~= "number" or pri < 1 then
		Log:warn(("lanePriority for lane '%s' is invalid; defaulting to 1"):format(tostring(laneName)))
		return 1
	end
	return math.floor(pri)
end

local function ensureLane(self, laneName)
	local lane = self.lanes[laneName]
	if lane then
		lane.priority = normalizePriority(self.lanePriorityFn(laneName) or 1, laneName)
		return lane
	end
	lane = newLaneState(normalizePriority(self.lanePriorityFn(laneName) or 1, laneName), self.ordering)
	self.lanes[laneName] = lane
	self.laneOrder[#self.laneOrder + 1] = laneName
	self.laneIndex[laneName] = #self.laneOrder
	return lane
end

local function selectLosingLane(self)
	-- Overflow policy: pick the *lowest priority* lane first, then rotate fairly among equals.
	local minPriority
	local candidates = {}
	for _, name in ipairs(self.laneOrder) do
		local lane = self.lanes[name]
		if lane and lane.pendingCount > 0 then
			local pri = lane.priority or 1
			if not minPriority or pri < minPriority then
				minPriority = pri
				candidates = { name }
			elseif pri == minPriority then
				candidates[#candidates + 1] = name
			end
		end
	end
	if #candidates == 0 then
		return nil
	end
	-- deterministic round robin over candidates list using rrEvictCursor
	local idx = ((self.rrEvictCursor - 1) % #candidates) + 1
	self.rrEvictCursor = self.rrEvictCursor + 1
	return candidates[idx]
end

local function evictOne(self)
	-- Global capacity guard: evict from the losing lane using mode-specific rules.
	local losingLaneName = selectLosingLane(self)
	if not losingLaneName then
		return false
	end
	local lane = self.lanes[losingLaneName]
	if self.mode == "queue" then
		-- Drop oldest entry (head) in the losing lane to preserve FIFO semantics.
		local head = lane.queueHead
		local entry
		while head <= lane.queueTail do
			entry = lane.queue[head]
			lane.queue[head] = nil
			head = head + 1
			if entry then
				break
			end
		end
		lane.queueHead = head
		if not entry then
			return false
		end
		if self.hooks.onDrop then
			pcall(self.hooks.onDrop, { reason = Reasons.dropOldest, key = entry.key, lane = losingLaneName })
		end
		lane.pendingCount = math.max(0, lane.pendingCount - 1)
		Metrics.bumpPending(self.metrics, -1, losingLaneName)
		lane.lastSeen[entry.key] = nil
		self.keyLane[entry.key] = nil
		Metrics.bumpTotal(self.metrics, "droppedTotal", 1)
		Metrics.bumpDropReason(self.metrics, Reasons.dropOldest)
		Metrics.bumpLaneDropped(self.metrics, losingLaneName, 1)
		self.dropDelta = self.dropDelta + 1
		return true
	end
	local victimKey = lanePopOldestKey(lane)
	if not victimKey then
		return false
	end
	lane.pending[victimKey] = nil
	lane.lastSeen[victimKey] = nil
	removeFromFifo(lane, victimKey)
	lane.pendingCount = math.max(0, lane.pendingCount - 1)
	Metrics.bumpPending(self.metrics, -1, losingLaneName)
	self.keyLane[victimKey] = nil
	-- LRU-by-ingestSeq keeps eviction fair even when duplicates refresh hot keys.
	if self.hooks.onDrop then
		pcall(self.hooks.onDrop, { reason = Reasons.evictLRU, key = victimKey, lane = losingLaneName })
	end
	Metrics.bumpTotal(self.metrics, "droppedTotal", 1)
	Metrics.bumpDropReason(self.metrics, Reasons.evictLRU)
	Metrics.bumpLaneDropped(self.metrics, losingLaneName, 1)
	self.dropDelta = self.dropDelta + 1
	return true
end

local function normalizeLaneName(name)
	if name == nil then
		return "default"
	end
	return tostring(name)
end

local function handleBadKey(self)
	Metrics.bumpTotal(self.metrics, "droppedTotal", 1)
	Metrics.bumpDropReason(self.metrics, Reasons.badKey)
	self.dropDelta = self.dropDelta + 1
	if self.hooks.onDrop then
		pcall(self.hooks.onDrop, { reason = Reasons.badKey })
	end
	if isHeadless() then
		Log:debug("Dropped item with nil key (badKey)")
	else
		Log:warn("Dropped item with nil key (badKey)")
	end
end

local function dequeueFromLane(self, laneName)
	local lane = self.lanes[laneName]
	if not lane or lane.pendingCount == 0 then
		return nil, nil
	end
	if self.ordering == "fifo" then
		local key, item = popFifo(lane)
		if key then
			return key, item
		end
	end
	return anyPending(lane)
end

local function removeFromLane(self, laneName, key)
	local lane = self.lanes[laneName]
	if not lane or not lane.pending[key] then
		return nil
	end
	lane.pending[key] = nil
	lane.lastSeen[key] = nil
	removeFromFifo(lane, key)
	lane.pendingCount = math.max(0, lane.pendingCount - 1)
	Metrics.bumpPending(self.metrics, -1, laneName)
	self.keyLane[key] = nil
	return true
end

local function pickLaneOrder(self)
	local lanes = {}
	for _, name in ipairs(self.laneOrder) do
		local lane = self.lanes[name]
		if lane and lane.pendingCount > 0 then
			lanes[#lanes + 1] = { name = name, priority = lane.priority or 1 }
		end
	end
	table.sort(lanes, function(a, b)
		if a.priority == b.priority then
			return self.laneIndex[a.name] < self.laneIndex[b.name]
		end
		return a.priority > b.priority
	end)
	return lanes
end

local function migrateKey(self, key, fromLane, toLaneName)
	local laneFrom = self.lanes[fromLane]
	local item = laneFrom and laneFrom.pending[key]
	local seen = laneFrom and laneFrom.lastSeen[key]
	if not item then
		return
	end
	-- We migrate to avoid split state where eviction priority and stored lane diverge.
	removeFromLane(self, fromLane, key)
	local laneTo = ensureLane(self, toLaneName)
	laneTo.priority = normalizePriority(self.lanePriorityFn(toLaneName) or 1, toLaneName)
	laneTo.pending[key] = item
	laneTo.lastSeen[key] = seen
	if type(seen) == "number" then
		heapPush(laneTo.lruHeap, { seq = seen, key = key })
	end
	laneTo.pendingCount = laneTo.pendingCount + 1
	Metrics.bumpPending(self.metrics, 1, toLaneName)
	if self.ordering == "fifo" and not laneTo.inFifo[key] then
		pushFifo(laneTo, key)
	end
	self.keyLane[key] = toLaneName
end

local function handleReplacement(self, laneName, key, oldItem, newItem)
	Metrics.bumpTotal(self.metrics, "replacedTotal", 1)
	self.replaceDelta = self.replaceDelta + 1
	if self.hooks.onReplace then
		pcall(self.hooks.onReplace, { old = oldItem, new = newItem, key = key, lane = laneName })
	end
end

local function addNewPending(self, laneName)
	Metrics.bumpTotal(self.metrics, "enqueuedTotal", 1)
	Metrics.bumpPending(self.metrics, 1, laneName)
end

local function laneHasSpace(self)
	return self.metrics.pending < self.capacity
end

local function ensureMode(self, mode)
	if self.mode ~= mode then
		error(("mode '%s' not implemented"):format(tostring(self.mode)))
	end
end

--- Enqueue an item into the buffer.
--- Cheap: only classifies lane/key and records lastSeen.
--- @param item any
function Buffer:ingest(item)
	Metrics.bumpTotal(self.metrics, "ingestedTotal", 1)
	local key = self.keyFn(item)
	if key == nil then
		handleBadKey(self)
		return
	end

	local laneName = normalizeLaneName(self.laneFn(item))
	local previousLane = self.keyLane[key]
	if previousLane and previousLane ~= laneName then
		migrateKey(self, key, previousLane, laneName)
	end
	local lane = ensureLane(self, laneName)
	lane.priority = normalizePriority(self.lanePriorityFn(laneName) or 1, laneName)
	self.keyLane[key] = laneName

	self.ingestSeq = self.ingestSeq + 1
	local seq = self.ingestSeq

	if self.mode == "latestByKey" then
		local existing = lane.pending[key]
		if existing ~= nil then
			lane.pending[key] = item
			lane.lastSeen[key] = seq
			heapPush(lane.lruHeap, { seq = seq, key = key })
			handleReplacement(self, laneName, key, existing, item)
		else
			lane.pending[key] = item
			lane.lastSeen[key] = seq
			heapPush(lane.lruHeap, { seq = seq, key = key })
			lane.pendingCount = lane.pendingCount + 1
			if self.ordering == "fifo" and not lane.inFifo[key] then
				pushFifo(lane, key)
			end
			addNewPending(self, laneName)
		end
	elseif self.mode == "dedupSet" then
		if lane.pending[key] ~= nil then
			-- Dedup: ignore duplicate pending; update lastSeen for eviction fairness.
			lane.lastSeen[key] = seq
			heapPush(lane.lruHeap, { seq = seq, key = key })
			Metrics.bumpTotal(self.metrics, "dedupedTotal", 1)
		else
			lane.pending[key] = item
			lane.lastSeen[key] = seq
			heapPush(lane.lruHeap, { seq = seq, key = key })
			lane.pendingCount = lane.pendingCount + 1
			if self.ordering == "fifo" and not lane.inFifo[key] then
				pushFifo(lane, key)
			end
			addNewPending(self, laneName)
		end
	elseif self.mode == "queue" then
		lane.pendingCount = lane.pendingCount + 1
		local entry = { key = key, item = item, seq = seq }
		lane.lastSeen[key] = seq
		lane.queueTail = lane.queueTail + 1
		lane.queue[lane.queueTail] = entry
		addNewPending(self, laneName)
	else
		error(("mode '%s' not implemented"):format(tostring(self.mode)))
	end

	-- Capacity enforcement (global).
	while self.metrics.pending > self.capacity do
		local evicted = evictOne(self)
		if not evicted then
			break
		end
	end
end

--- Drain buffered work under a budget.
--- @param opts table
--- @return table stats
function Buffer:drain(opts)
	opts = opts or {}
	local maxItems = opts.maxItems or 0
	if type(maxItems) ~= "number" or maxItems < 0 then
		maxItems = 0
	end
	if maxItems > 0 and type(opts.handle) ~= "function" then
		error("drain requires handle function when maxItems > 0")
	end

	local useClock = false
	local startClock = nil
	if opts.maxMillis ~= nil then
		if type(opts.maxMillis) ~= "number" or opts.maxMillis <= 0 then
			Log:warn("maxMillis invalid; skipping drain")
			return { processed = 0, pending = self.metrics.pending, dropped = 0, replaced = 0, spentMillis = nil }
		end
		if type(opts.nowMillis) ~= "function" then
			Log:warn("nowMillis missing; skipping drain time budget")
			return { processed = 0, pending = self.metrics.pending, dropped = 0, replaced = 0, spentMillis = nil }
		end
		startClock = opts.nowMillis()
		if type(startClock) ~= "number" then
			Log:warn("nowMillis did not return a number; skipping drain")
			return { processed = 0, pending = self.metrics.pending, dropped = 0, replaced = 0, spentMillis = nil }
		end
		useClock = true
	end

	if self.hooks.onDrainStart then
		pcall(self.hooks.onDrainStart, { nowMillis = startClock, maxItems = maxItems, maxMillis = opts.maxMillis })
	end

	local processed = 0
	local spentMillis = nil
	local lanesOrdered = pickLaneOrder(self)
	local laneIdx = 1

	while processed < maxItems and self.metrics.pending > 0 do
		local entry = lanesOrdered[laneIdx]
		if not entry then
			break
		end
		local laneName = entry.name
		local key, item
		if self.mode == "queue" then
			local lane = self.lanes[laneName]
			local head = lane.queueHead
			while head <= lane.queueTail do
				local entry = lane.queue[head]
				lane.queue[head] = nil
				head = head + 1
				if entry then
					key = entry.key
					item = entry.item
					break
				end
			end
			lane.queueHead = head
			if key ~= nil then
				lane.pendingCount = math.max(0, lane.pendingCount - 1)
				Metrics.bumpPending(self.metrics, -1, laneName)
				self.keyLane[key] = nil
				lane.lastSeen[key] = nil
			end
		else
			key, item = dequeueFromLane(self, laneName)
			if key ~= nil then
				removeFromLane(self, laneName, key)
			end
		end

		if key == nil then
			-- This lane is empty; move on.
			laneIdx = laneIdx + 1
		else
			if opts.handle then
				opts.handle(item)
			end
			processed = processed + 1
			Metrics.bumpTotal(self.metrics, "drainedTotal", 1)
			Metrics.bumpLaneDrained(self.metrics, laneName, 1)
			if useClock then
				local now = opts.nowMillis()
				if type(now) ~= "number" then
					Log:warn("nowMillis did not return a number during drain; aborting")
					spentMillis = nil
					break
				end
				if now < startClock then
					Log:warn("nowMillis is non-monotonic; aborting drain")
					spentMillis = nil
					break
				end
				spentMillis = now - startClock
				if spentMillis >= opts.maxMillis then
					break
				end
			end
		end
	end

	self.metrics.totals.drainCallsTotal = self.metrics.totals.drainCallsTotal + 1

	local oldestSeq, newestSeq, span = (function()
		local minSeq, maxSeq
		for _, laneState in pairs(self.lanes) do
			for _, seq in pairs(laneState.lastSeen) do
				if type(seq) == "number" then
					if not minSeq or seq < minSeq then
						minSeq = seq
					end
					if not maxSeq or seq > maxSeq then
						maxSeq = seq
					end
				end
			end
		end
		return minSeq, maxSeq, (minSeq and maxSeq) and (maxSeq - minSeq) or 0
	end)()

	Metrics.accumulateAverages(self.metrics, span)
	-- Load-style averages (EWMA over pending + throughput). Uses nowMillis when provided; falls back to os.clock.
	local ingestedDelta = self.metrics.totals.ingestedTotal - (self.lastLoadIngestedTotal or self.metrics.totals.ingestedTotal)
	self.lastLoadIngestedTotal = self.metrics.totals.ingestedTotal
	Metrics.updateLoad(self.metrics, self.metrics.pending, processed, ingestedDelta, opts.nowMillis)
	if spentMillis and processed > 0 then
		Metrics.updateMsPerItem(self.metrics, spentMillis / processed)
	end

	local stats = {
		processed = processed,
		pending = self.metrics.pending,
		dropped = self.dropDelta,
		replaced = self.replaceDelta,
		spentMillis = spentMillis,
	}
	Metrics.updateLastDrain(self.metrics, {
		processed = processed,
		pendingAfter = self.metrics.pending,
		dropped = self.dropDelta,
		replaced = self.replaceDelta,
		spentMillis = spentMillis,
	})

	-- Reset deltas after reporting.
	self.dropDelta = 0
	self.replaceDelta = 0

	if self.hooks.onDrainEnd then
		pcall(self.hooks.onDrainEnd, stats)
	end

	return stats
end

--- Snapshot metrics (totals + per-lane).
--- @return table
function Buffer:metrics_get()
	return Metrics.snapshot(self.metrics, self.lanes)
end

--- Reset metrics/peaks without touching buffered items.
function Buffer:metrics_reset()
	Metrics.reset(self.metrics)
	-- Recompute pending/per-lane baselines without touching buffered items.
	local total = 0
	for laneName, laneState in pairs(self.lanes) do
		if laneState.pendingCount > 0 then
			total = total + laneState.pendingCount
			self.metrics.perLane[laneName] = {
				pending = laneState.pendingCount,
				peakPending = laneState.pendingCount,
				drainedTotal = 0,
				droppedTotal = 0,
				seqSpan = 0,
			}
		end
	end
	self.metrics.pending = total
	self.metrics.peakPending = total
end

--- Remove all buffered items; keep historical totals/averages intact.
function Buffer:clear()
	-- Drop all buffered items without altering historical totals.
	local removed = self.metrics.pending
	for laneName, laneState in pairs(self.lanes) do
		laneState.pending = {}
		laneState.lastSeen = {}
		laneState.pendingCount = 0
		laneState.lruHeap = {}
		laneState.fifo = {}
		laneState.fifoHead = 1
		laneState.inFifo = {}
		laneState.queue = {}
		laneState.queueHead = 1
		laneState.queueTail = 0
		-- Per-lane metrics snapshot resets to 0 pending; totals stay.
		self.metrics.perLane[laneName] = {
			pending = 0,
			peakPending = 0,
			drainedTotal = self.metrics.perLane[laneName] and self.metrics.perLane[laneName].drainedTotal or 0,
			droppedTotal = self.metrics.perLane[laneName] and self.metrics.perLane[laneName].droppedTotal or 0,
			seqSpan = 0,
		}
	end
	self.keyLane = {}
	self.metrics.pending = 0
	self.metrics.peakPending = 0
	self.metrics.lastDrain = self.metrics.lastDrain or {}
	self.rrEvictCursor = 1
	self.dropDelta = 0
	self.replaceDelta = 0
	Log:info("Cleared buffer '%s' (removed %d pending)", self.name, removed or 0)
end

--- Provide a simple recommendation for next drain budget and trend.
--- @param opts table|nil
--- @return table
function Buffer:advice_get(opts)
	opts = opts or {}
	local snap = self:metrics_get()
	local load1 = snap.load1 or 0
	local load15 = snap.load15 or 0
	local throughput15 = snap.throughput15 or 0
	local ingestRate15 = snap.ingestRate15 or 0
	local dt = snap.lastDtSeconds or opts.drainIntervalSeconds
	local epsilon = opts.epsilon or 0.1

	local trend = "steady"
	if (load1 - load15) > epsilon and throughput15 < ingestRate15 then
		trend = "rising"
	elseif (load1 - load15) < -epsilon and throughput15 >= ingestRate15 then
		trend = "falling"
	end

	local targetClearSeconds = opts.targetClearSeconds or 0
	-- When targetClearSeconds is omitted/0, recommend steady-state throughput only (keep up with arrivals).
	-- When set, add a catch-up term that tries to eat into backlog over that time horizon.
	local recommendedThroughput = ingestRate15
	if targetClearSeconds > 0 then
		recommendedThroughput = recommendedThroughput + ((load15 or 0) / targetClearSeconds)
	end
	local recommendedMaxItems = nil
	if dt and dt > 0 then
		recommendedMaxItems = math.ceil(recommendedThroughput * dt)
	end

	return {
		trend = trend,
		ingestRate = ingestRate15,
		throughput = throughput15,
		load = load15,
		recommendedThroughput = recommendedThroughput,
		recommendedMaxItems = recommendedMaxItems,
		msPerItem = snap.msPerItemEma,
		drainIntervalSeconds = dt,
	}
end

--- Apply advice to update maxItems with smoothing and clamping.
--- @param current number|nil
--- @param opts table|nil
--- @return number, table
function Buffer:advice_applyMaxItems(current, opts)
	opts = opts or {}
	local advice = self:advice_get(opts)
	local newMax = current or 0
	if advice.recommendedMaxItems then
		local alpha = opts.alpha or 0
		if alpha > 0 and alpha < 1 then
			newMax = math.floor(((1 - alpha) * newMax) + (alpha * advice.recommendedMaxItems))
		else
			newMax = advice.recommendedMaxItems
		end
	end
	local minItems = opts.minItems or 0
	local maxItemsCap = opts.maxItems or opts.maxItemsCap
	if newMax < minItems then
		newMax = minItems
	end
	if maxItemsCap and newMax > maxItemsCap then
		newMax = maxItemsCap
	end
	return newMax, advice
end

--- Apply advice to update maxMillis (requires msPerItem estimates).
--- @param current number|nil
--- @param opts table|nil
--- @return number, table
function Buffer:advice_applyMaxMillis(current, opts)
	opts = opts or {}
	local advice = self:advice_get(opts)
	local msPerItem = advice.msPerItem
	if not msPerItem or msPerItem <= 0 or not advice.recommendedMaxItems then
		-- Avoid noisy warnings in headless/busted runs where timing data may be intentionally absent.
		if isHeadless() then
			Log:debug("advice_applyMaxMillis insufficient timing data to recommend maxMillis")
		else
			Log:warn("advice_applyMaxMillis insufficient timing data to recommend maxMillis")
		end
		return current or 0, advice
	end
	local recommendedMaxMillis = advice.recommendedMaxItems * msPerItem
	local alpha = opts.alpha or 0
	local newMax = current or 0
	if alpha > 0 and alpha < 1 then
		newMax = ((1 - alpha) * newMax) + (alpha * recommendedMaxMillis)
	else
		newMax = recommendedMaxMillis
	end
	local minMillis = opts.minMillis or 0
	local maxMillisCap = opts.maxMillis or opts.maxMillisCap
	if newMax < minMillis then
		newMax = minMillis
	end
	if maxMillisCap and newMax > maxMillisCap then
		newMax = maxMillisCap
	end
	return newMax, advice
end

--- Construct a new ingest buffer.
--- @param opts LQRIngestBufferOpts
--- @return LQRIngestBuffer
function Buffer.new(opts)
	validateOpts(opts)
	local self = setmetatable({}, Buffer)
	self.name = opts.name
	self.mode = opts.mode
	self.capacity = math.floor(opts.capacity)
	self.keyFn = opts.key
	self.laneFn = opts.lane or defaultLane
	self.lanePriorityFn = opts.lanePriority or defaultLanePriority
	self.ordering = opts.ordering or "none"
	self.hooks = {
		onDrainStart = opts.onDrainStart,
		onDrainEnd = opts.onDrainEnd,
		onDrop = opts.onDrop,
		onReplace = opts.onReplace,
	}
	self.metrics = Metrics.new(self.name)
	self.lanes = {}
	self.laneOrder = {}
	self.laneIndex = {}
	self.rrEvictCursor = 1
	self.ingestSeq = 0
	self.dropDelta = 0
	self.replaceDelta = 0
	self.keyLane = {}
	self.lastLoadIngestedTotal = 0
	if self.mode == "queue" and self.ordering ~= "none" then
		Log:warn("ordering is ignored for queue mode; provided ordering='%s'", tostring(self.ordering))
	end
	Log:info(
		"Created buffer '%s' (mode=%s, capacity=%d, ordering=%s)",
		self.name,
		self.mode,
		self.capacity,
		self.ordering
	)
	return self
end

return Buffer
