local Log = require("LQR/util/log").withTag("ingest.scheduler")

local Scheduler = {}
Scheduler.__index = Scheduler

--- @class LQRIngestSchedulerOpts
--- @field name string
--- @field maxItemsPerTick integer

--- @class LQRIngestScheduler
--- @field addBuffer fun(self:LQRIngestScheduler, buffer:any, opts:table)
--- @field drainTick fun(self:LQRIngestScheduler, handleFn:function):table
--- @field metrics_get fun(self:LQRIngestScheduler):table
--- @field metrics_reset fun(self:LQRIngestScheduler)

local function validateOpts(opts)
	assert(type(opts) == "table", "opts table required")
	assert(type(opts.name) == "string" and opts.name ~= "", "name is required")
	assert(type(opts.maxItemsPerTick) == "number" and opts.maxItemsPerTick >= 0, "maxItemsPerTick must be >= 0")
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
--- @return table
function Scheduler:drainTick(handleFn)
	local remaining = self.maxItemsPerTick
	local aggProcessed, aggDropped, aggReplaced, aggPending = 0, 0, 0, 0

	for _, entry in ipairs(self._buffers) do
		if remaining <= 0 then
			break
		end
		local stats = entry.buffer:drain({
			maxItems = remaining,
			handle = handleFn,
		}) or {}
		aggProcessed = aggProcessed + (stats.processed or 0)
		aggDropped = aggDropped + (stats.dropped or 0)
		aggReplaced = aggReplaced + (stats.replaced or 0)
		aggPending = aggPending + (stats.pending or 0)
		remaining = remaining - (stats.processed or 0)
	end

	self.totals.drainCallsTotal = self.totals.drainCallsTotal + 1
	self.totals.drainedTotal = self.totals.drainedTotal + aggProcessed
	self.lastStats = {
		processed = aggProcessed,
		dropped = aggDropped,
		replaced = aggReplaced,
		pending = aggPending,
	}

	return self.lastStats
end

--- Snapshot metrics for scheduler and child buffers.
function Scheduler:metrics_get()
	local buffers = {}
	local pendingSum, droppedSum, replacedSum, drainedSum = 0, 0, 0, 0
	for _, entry in ipairs(self._buffers) do
		local snap = entry.buffer:metrics_get()
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
	self._buffers = {}
	self.totals = {
		drainCallsTotal = 0,
		drainedTotal = 0,
	}
	self.lastStats = {
		processed = 0,
		dropped = 0,
		replaced = 0,
		pending = 0,
	}
	return self
end

return Scheduler
