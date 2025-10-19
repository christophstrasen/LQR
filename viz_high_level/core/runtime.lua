-- Headless-friendly high-level viz runtime that consumes normalized adapter events
-- and maintains expandable grid/window state plus per-layer event buffers.
local Runtime = {}
Runtime.__index = Runtime

local DEFAULT_ADJUST_INTERVAL = 2
local DEFAULT_MARGIN_COLUMNS_PERCENT = 0.2
local DEFAULT_MIX_HALF_LIFE = DEFAULT_ADJUST_INTERVAL
local ZOOM_SMALL = { columns = 10, rows = 10 }
local ZOOM_LARGE = { columns = 100, rows = 100 }
local SLIDE_BUFFER_PERCENT = 0.2

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
	self.autoZoom = not (opts.maxColumns or opts.maxRows)
	if self.autoZoom then
		self.windowConfig = { columns = ZOOM_SMALL.columns, rows = ZOOM_SMALL.rows }
		self.zoomState = "small"
	else
		self.windowConfig = {
			columns = opts.maxColumns or ZOOM_SMALL.columns,
			rows = opts.maxRows or ZOOM_SMALL.rows,
		}
		self.zoomState = "manual"
	end
	self.adjustInterval = opts.adjustInterval or DEFAULT_ADJUST_INTERVAL
	self.marginAbsolute = opts.margin
	self.marginPercent = opts.marginPercent or DEFAULT_MARGIN_COLUMNS_PERCENT
	self.maxLayers = opts.maxLayers or 5
	self.palette = opts.palette or {}
	self.header = opts.header or {}
	self.mixDecayHalfLife = opts.mixDecayHalfLife or opts.adjustInterval or DEFAULT_MIX_HALF_LIFE
	self.activeIds = {}
	self.observedMin = nil
	self.observedMax = nil
	self.gridStart = opts.startId or 0
	self.gridEnd = self.gridStart + (self.windowConfig.columns * self.windowConfig.rows) - 1
	self.lastAdjust = opts.now or 0
	self.lastIngestTime = opts.now or 0
	self.events = {
		source = {},
		match = {},
		expire = {},
	}
	self.zoomState = self.autoZoom and "small" or "manual"
	return self
end

local function windowSize(self)
	return (self.windowConfig.columns or ZOOM_SMALL.columns)
		* (self.windowConfig.rows or ZOOM_SMALL.rows)
end

local function collectActiveIds(self, now)
	local minId, maxId, count = nil, nil, 0
	local ttl = (self.mixDecayHalfLife or DEFAULT_MIX_HALF_LIFE) * 4
	for id, lastSeen in pairs(self.activeIds) do
		if now - lastSeen <= ttl then
			minId = minId and math.min(minId, id) or id
			maxId = maxId and math.max(maxId, id) or id
			count = count + 1
		else
			self.activeIds[id] = nil
		end
	end
	return minId, maxId, count
end

local function effectiveMargin(self)
	if self.marginAbsolute ~= nil then
		return self.marginAbsolute
	end
	local percent = self.marginPercent or DEFAULT_MARGIN_COLUMNS_PERCENT
	if percent < 0 then
		percent = 0
	elseif percent > 1 then
		percent = 1
	end
	local columns = self.windowConfig.columns or ZOOM_SMALL.columns
	local rows = self.windowConfig.rows or ZOOM_SMALL.rows
	local reserveColumns = math.max(1, math.floor(columns * percent))
	return reserveColumns * rows
end

local function manualAdjust(self, now)
	if not self.observedMin or not self.observedMax then
		self.lastAdjust = now
		return
	end

	local marginValue = effectiveMargin(self)
	local desiredMin = self.observedMin - marginValue
	local desiredMax = self.observedMax + marginValue

	local span = desiredMax - desiredMin + 1
	local maxSpan = windowSize(self)
	if span > maxSpan then
		span = maxSpan
	end
	local start = desiredMin
	local finish = desiredMin + span - 1

	if finish < desiredMax then
		start = desiredMax - span + 1
		finish = desiredMax
	end

	local rowBase = self.windowConfig.rows or 10
	start = math.floor(start / rowBase) * rowBase
	finish = start + (self.windowConfig.columns * self.windowConfig.rows) - 1
	self.gridStart = start
	self.gridEnd = finish
	self.lastAdjust = now
end

function Runtime:_maybeAdjust(now)
	if not now then
		return
	end
	if self.lastAdjust and (now - self.lastAdjust) < self.adjustInterval then
		return
	end

	if not self.autoZoom then
		manualAdjust(self, now)
		return
	end

	local activeMin, activeMax, activeCount = collectActiveIds(self, now)
	if not activeMin or not activeMax then
		self.lastAdjust = now
		return
	end
	local function fitsIn(width)
		return activeCount <= width * width
	end

	local resized = false
	if self.windowConfig.columns == ZOOM_SMALL.columns and not fitsIn(ZOOM_SMALL.columns) then
		self.windowConfig = { columns = ZOOM_LARGE.columns, rows = ZOOM_LARGE.rows }
		self.zoomState = "large"
		resized = true
	elseif self.windowConfig.columns == ZOOM_LARGE.columns and fitsIn(ZOOM_SMALL.columns) then
		self.windowConfig = { columns = ZOOM_SMALL.columns, rows = ZOOM_SMALL.rows }
		self.zoomState = "small"
		resized = true
	end

	local range = windowSize(self)
	local buffer = math.floor(range * SLIDE_BUFFER_PERCENT)
	local visibleSpan = range - buffer
	if visibleSpan < 1 then
		visibleSpan = range
	end

	local start = activeMin
	if (activeMax - start + 1) > visibleSpan then
		start = activeMax - visibleSpan + 1
	end
	if start < 0 then
		start = 0
	end
	local rowBase = self.windowConfig.rows or 10
	start = math.floor(start / rowBase) * rowBase
	local finish = start + range - 1

	local spanFits = (activeMax - start + 1) <= range
	if not spanFits then
		start = math.max(activeMax - range + 1, 0)
		start = math.floor(start / rowBase) * rowBase
		finish = start + range - 1
		self.zoomState = "compressed"
	elseif resized then
		self.zoomState = (self.windowConfig.columns == ZOOM_LARGE.columns) and "large" or "small"
	end

	self.gridStart = start
	self.gridEnd = finish
	self.lastAdjust = now
end

function Runtime:ingest(event, now)
	if not event or not event.type then
		return
	end
	local timestamp = now or self.lastIngestTime or 0
	event.ingestTime = timestamp
	self.lastIngestTime = timestamp

	if event.type == "source" then
		local id = normalizeId(event.id)
		if id ~= nil then
			self.observedMin = self.observedMin and math.min(self.observedMin, id) or id
			self.observedMax = self.observedMax and math.max(self.observedMax, id) or id
			table.insert(self.events.source, event)
		end
	elseif event.type == "match" or event.type == "joinresult" then
		event.layer = clamp(event.layer or 1, 1, self.maxLayers)
		table.insert(self.events.match, event)
	elseif event.type == "expire" then
		event.layer = clamp(event.layer or 1, 1, self.maxLayers)
		table.insert(self.events.expire, event)
	end

	if event.type == "source" and event.projectable then
		local id = normalizeId(event.projectionKey or event.id)
		if id ~= nil then
			self.activeIds[id] = timestamp
		end
	end

	if event.type == "source" then
		self:_maybeAdjust(now)
	end
end

function Runtime:window()
	return {
		startId = self.gridStart,
		endId = self.gridEnd,
		columns = self.windowConfig.columns,
		rows = self.windowConfig.rows,
		margin = effectiveMargin(self),
		marginPercent = self.marginPercent,
		zoomState = self.zoomState,
		gc = self.gc,
	}
end

Runtime.new = new

return Runtime
