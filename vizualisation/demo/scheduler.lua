-- Deterministic timeline scheduler: consumes ordered events and dispatches them once
-- their scheduled tick is reached. Callers can advance by wall-clock deltas (scaled
-- into ticks) or jump directly to a tick for headless snapshots.
---@class VizDemoScheduler
---@field tick number
---@field speed number
---@field events table
---@field index integer
---@field handlers table
local Scheduler = {}
Scheduler.__index = Scheduler

local function cloneEvents(events)
	local copy = {}
	for i, event in ipairs(events or {}) do
		copy[i] = event
	end
	table.sort(copy, function(a, b)
		if a.tick == b.tick then
			return (a.order or 0) < (b.order or 0)
		end
		return (a.tick or 0) < (b.tick or 0)
	end)
	return copy
end

---@param opts table
---@return VizDemoScheduler
function Scheduler.new(opts)
	opts = opts or {}
	local self = setmetatable({}, Scheduler)
	self.tick = opts.startTick or 0
	self.speed = opts.speed or 1
	self.handlers = opts.handlers or {}
	self.events = cloneEvents(opts.events)
	self.index = 1
	self.finished = (#self.events == 0)
	return self
end

function Scheduler:_dispatch(event)
	local kind = event.kind or "emit"
	local handler = self.handlers[kind]
	if handler then
		handler(event)
	end
end

local function hasPending(self)
	return (self.index <= #self.events)
end

function Scheduler:advance(deltaTicks)
	if self.finished then
		self.tick = self.tick + (deltaTicks or 0)
		return
	end
	local delta = deltaTicks or 0
	if delta <= 0 then
		delta = 0
	end
	self.tick = self.tick + delta
	while hasPending(self) do
		local event = self.events[self.index]
		if not event or (event.tick or 0) > self.tick then
			break
		end
		self.index = self.index + 1
		self:_dispatch(event)
	end
	if not hasPending(self) then
		self.finished = true
	end
end

function Scheduler:runUntil(targetTick)
	if self.finished then
		self.tick = targetTick or self.tick
		return
	end
	local target = targetTick or self.tick
	if target < self.tick then
		self.tick = target
		return
	end
	local delta = target - self.tick
	self:advance(delta)
end

function Scheduler:drain()
	while not self.finished do
		local nextEvent = self.events[self.index]
		if not nextEvent then
			self.finished = true
			break
		end
		self:runUntil(nextEvent.tick or self.tick)
		if self.finished then
			break
		end
		-- Ensure we advance slightly so events sharing the same tick are drained.
		if self.events[self.index] and (self.events[self.index].tick or 0) == self.tick then
			self:advance(0)
		end
	end
end

function Scheduler:isFinished()
	return self.finished
end

function Scheduler:currentTick()
	return self.tick
end

return Scheduler
