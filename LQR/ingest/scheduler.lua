local Log = require("LQR/util/log").withTag("ingest.scheduler")

local Scheduler = {}
Scheduler.__index = Scheduler

--- @class LQRIngestSchedulerOpts
--- @field name string
--- @field maxItemsPerTick integer
--- @field quantum integer|nil @Optional: max items per buffer turn (RR). Defaults to 1.
--- @field maxMillisPerTick integer|nil @Optional: wall-clock budget per tick (requires nowMillis)

--- @class LQRIngestScheduler
--- @field addBuffer fun(self:LQRIngestScheduler, buffer:any, opts:table)
--- @field drainTick fun(self:LQRIngestScheduler, handleFn:function, opts:table|nil):table
--- @field metrics_get fun(self:LQRIngestScheduler):table
--- @field metrics_reset fun(self:LQRIngestScheduler)

local function validateOpts(opts)
	assert(type(opts) == "table", "opts table required")
	assert(type(opts.name) == "string" and opts.name ~= "", "name is required")
	assert(type(opts.maxItemsPerTick) == "number" and opts.maxItemsPerTick >= 0, "maxItemsPerTick must be >= 0")
	if opts.quantum ~= nil then
		assert(type(opts.quantum) == "number" and opts.quantum >= 1, "quantum must be >= 1 when provided")
	end
end

local function resolveDrainArgs(arg1, arg2)
	-- Backwards compatible:
	-- - drainTick(handleFn)
	-- - drainTick(handleFn, { nowMillis = fn })
	-- - drainTick({ handle = handleFn, nowMillis = fn })
	if type(arg1) == "function" then
		return arg1, type(arg2) == "table" and arg2 or {}
	end
	if type(arg1) == "table" then
		local opts = arg1
		assert(type(opts.handle) == "function", "drainTick requires opts.handle function")
		return opts.handle, opts
	end
	error("drainTick requires handle function or opts table")
end

local function newBufferEntry(buffer, priority, index)
	return {
		buffer = buffer,
		priority = priority or 1,
		index = index or 1,
	}
end

local function sortBuffers(buffers)
	-- Deterministic ordering: higher priority first, then stable by insertion index.
	table.sort(buffers, function(a, b)
		if a.priority == b.priority then
			return a.index < b.index
		end
		return a.priority > b.priority
	end)
end

--- Attach a buffer to the scheduler.
--- @param buffer any
--- @param opts table
function Scheduler:addBuffer(buffer, opts)
	assert(buffer and buffer.drain, "buffer with drain required")
	local priority = (opts and opts.priority) or 1
	if type(priority) ~= "number" or priority < 1 then
		Log:warn("buffer priority invalid; defaulting to 1")
		priority = 1
	end
	self._buffers[#self._buffers + 1] = newBufferEntry(buffer, priority, #self._buffers + 1)
	sortBuffers(self._buffers)
	Log:info("Scheduler '%s' added buffer '%s' (priority=%d)", self.name, buffer.name or "anon", priority)
end

--- Drain buffers in priority order under the global budget.
--- @param handleFn function
--- @param opts table|nil
--- @return table
function Scheduler:drainTick(handleFn, opts)
	handleFn, opts = resolveDrainArgs(handleFn, opts)
	local nowMillis = opts and opts.nowMillis
	local remaining = self.maxItemsPerTick
	local remainingMs = (opts and opts.maxMillisPerTick) or self.maxMillisPerTick
	local totalSpentMs = 0
	local aggProcessed, aggDropped, aggReplaced, aggPending = 0, 0, 0, 0

	-- Explainer: Scheduler fairness.
	-- In v1 we keep it simple:
	-- - Different priorities are drained in descending priority order.
	-- - Buffers of the same priority are drained round-robin with a small quantum,
	--   so one hot buffer can't starve its peers forever.
	local quantum = self.quantum or 1

	-- Iterate priority groups (buffers are already sorted by priority desc, then insertion index).
	local idx = 1
	while idx <= #self._buffers and remaining > 0 do
		local pri = self._buffers[idx].priority or 1
		local groupStart = idx
		local groupEnd = idx
		while groupEnd <= #self._buffers and (self._buffers[groupEnd].priority or 1) == pri do
			groupEnd = groupEnd + 1
		end
		groupEnd = groupEnd - 1

		-- Drain this group in RR slices until we run out of budget or nobody makes progress.
		local n = groupEnd - groupStart + 1
		local cursor = self._rrCursorByPriority[pri] or 1
		if cursor < 1 or cursor > n then
			cursor = 1
		end

		while remaining > 0 do
			local progressed = false
			for _ = 1, n do
				if remaining <= 0 then
					break
				end
				local entry = self._buffers[groupStart + (cursor - 1)]
				cursor = (cursor % n) + 1

				local drainOpts = {
					maxItems = math.min(quantum, remaining),
					handle = handleFn,
					nowMillis = nowMillis,
				}
				if remainingMs and remainingMs > 0 then
					drainOpts.maxMillis = remainingMs
				end

				local stats = entry.buffer:drain(drainOpts) or {}

				aggProcessed = aggProcessed + (stats.processed or 0)
				aggDropped = aggDropped + (stats.dropped or 0)
				aggReplaced = aggReplaced + (stats.replaced or 0)
				aggPending = aggPending + (stats.pending or 0)
				remaining = remaining - (stats.processed or 0)
				if remainingMs and stats.spentMillis and type(stats.spentMillis) == "number" then
					remainingMs = remainingMs - stats.spentMillis
					totalSpentMs = totalSpentMs + stats.spentMillis
				end

				if (stats.processed or 0) > 0 then
					progressed = true
				end
				if remainingMs and remainingMs <= 0 then
					progressed = false
					break
				end
			end
			if not progressed then
				break
			end
		end

		self._rrCursorByPriority[pri] = cursor
		idx = groupEnd + 1
	end

	self.totals.drainCallsTotal = self.totals.drainCallsTotal + 1
	self.totals.drainedTotal = self.totals.drainedTotal + aggProcessed
	self.lastStats = {
		processed = aggProcessed,
		dropped = aggDropped,
		replaced = aggReplaced,
		pending = aggPending,
		spentMillis = totalSpentMs,
	}

	return self.lastStats
end

--- Snapshot metrics for scheduler and child buffers.
function Scheduler:metrics_get()
	local buffers = {}
	local pendingSum, droppedSum, replacedSum, drainedSum = 0, 0, 0, 0
	for _, entry in ipairs(self._buffers) do
		local snap
		if entry.buffer.metrics_getLight then
			snap = entry.buffer:metrics_getLight()
		else
			snap = entry.buffer:metrics_get()
		end
		buffers[entry.buffer.name or tostring(entry)] = snap
		pendingSum = pendingSum + (snap.pending or 0)
		droppedSum = droppedSum + (snap.totals and snap.totals.droppedTotal or 0)
		replacedSum = replacedSum + (snap.totals and snap.totals.replacedTotal or 0)
		drainedSum = drainedSum + (snap.totals and snap.totals.drainedTotal or 0)
	end

	return {
		name = self.name,
		pending = pendingSum,
		droppedTotal = droppedSum,
		replacedTotal = replacedSum,
		drainedTotal = drainedSum,
		drainCallsTotal = self.totals.drainCallsTotal,
		lastDrain = self.lastStats,
		buffers = buffers,
	}
end

--- Reset metrics for scheduler and all attached buffers.
function Scheduler:metrics_reset()
	self.totals = {
		drainCallsTotal = 0,
		drainedTotal = 0,
	}
	self.lastStats = {
		processed = 0,
		dropped = 0,
		replaced = 0,
		pending = 0,
		spentMillis = 0,
	}
	for _, entry in ipairs(self._buffers) do
		if entry.buffer.metrics_reset then
			entry.buffer:metrics_reset()
		end
	end
end

--- Construct a scheduler helper.
--- @param opts LQRIngestSchedulerOpts
--- @return LQRIngestScheduler
function Scheduler.new(opts)
	validateOpts(opts)
	local self = setmetatable({}, Scheduler)
	self.name = opts.name
	self.maxItemsPerTick = opts.maxItemsPerTick
	self.quantum = opts.quantum or 1
	self.maxMillisPerTick = opts.maxMillisPerTick
	self._buffers = {}
	self._rrCursorByPriority = {}
	self.totals = {
		drainCallsTotal = 0,
		drainedTotal = 0,
	}
	self.lastStats = {
		processed = 0,
		dropped = 0,
		replaced = 0,
		pending = 0,
		spentMillis = 0,
	}
	return self
end

return Scheduler
