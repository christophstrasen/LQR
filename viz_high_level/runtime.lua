-- Headless-friendly high-level viz runtime that consumes normalized adapter events
-- and maintains expandable grid/window state plus per-layer event buffers.
local Runtime = {}
Runtime.__index = Runtime

local DEFAULT_ADJUST_INTERVAL = 2
local DEFAULT_MAX_COLUMNS = 100
local DEFAULT_MAX_ROWS = 100
local DEFAULT_MARGIN = 2

local function clamp(value, min, max)
	if value < min then
		return min
	end
	if value > max then
		return max
	end
	return value
end

local function normalizeId(value)
	if value == nil then
		return nil
	end
	if type(value) == "number" then
		return value
	end
	return tonumber(value)
end

local function new(opts)
	opts = opts or {}
	local self = setmetatable({}, Runtime)
	self.maxColumns = opts.maxColumns or DEFAULT_MAX_COLUMNS
	self.maxRows = opts.maxRows or DEFAULT_MAX_ROWS
	self.adjustInterval = opts.adjustInterval or DEFAULT_ADJUST_INTERVAL
	self.margin = opts.margin or DEFAULT_MARGIN
	self.maxLayers = opts.maxLayers or 5
	self.palette = opts.palette or {}
	self.header = opts.header or {}
	self.observedMin = nil
	self.observedMax = nil
	self.gridStart = opts.startId or 1
	self.gridEnd = self.gridStart + (self.maxColumns * self.maxRows) - 1
	self.lastAdjust = opts.now or 0
	self.events = {
		source = {},
		match = {},
		expire = {},
	}
	return self
end

local function windowSize(self)
	return self.maxColumns * self.maxRows
end

function Runtime:_maybeAdjust(now)
	if not now then
		return
	end
	if self.lastAdjust and (now - self.lastAdjust) < self.adjustInterval then
		return
	end
	if not self.observedMin or not self.observedMax then
		self.lastAdjust = now
		return
	end

	local desiredMin = self.observedMin - self.margin
	local desiredMax = self.observedMax + self.margin

	local span = desiredMax - desiredMin + 1
	if span > windowSize(self) then
		span = windowSize(self)
	end
	local start = desiredMin
	local finish = desiredMin + span - 1

	if finish < desiredMax then
		start = desiredMax - span + 1
		finish = desiredMax
	end

	self.gridStart = start
	self.gridEnd = finish
	self.lastAdjust = now
end

function Runtime:ingest(event, now)
	if not event or not event.type then
		return
	end
	if event.type == "source" then
		local id = normalizeId(event.id)
		if id ~= nil then
			self.observedMin = self.observedMin and math.min(self.observedMin, id) or id
			self.observedMax = self.observedMax and math.max(self.observedMax, id) or id
			table.insert(self.events.source, event)
			self:_maybeAdjust(now)
		end
	elseif event.type == "match" then
		event.layer = clamp(event.layer or 1, 1, self.maxLayers)
		table.insert(self.events.match, event)
	elseif event.type == "expire" then
		event.layer = clamp(event.layer or 1, 1, self.maxLayers)
		table.insert(self.events.expire, event)
	end
end

function Runtime:window()
	return {
		startId = self.gridStart,
		endId = self.gridEnd,
		columns = self.maxColumns,
		rows = self.maxRows,
		gc = self.gc,
	}
end

Runtime.new = new

return Runtime
