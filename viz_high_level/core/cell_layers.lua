local Log = require("log")

local CellLayer = {}
CellLayer.__index = CellLayer

local function nowSeconds()
	return love and love.timer and love.timer.getTime() or os.clock()
end

local function cloneColor(color)
	return {
		(color and color[1]) or 0,
		(color and color[2]) or 0,
		(color and color[3]) or 0,
		(color and color[4]) or 1,
	}
end

local function newLayer(bgColor, ttl)
	return setmetatable({
		bgColor = cloneColor(bgColor or { 0, 0, 0, 1 }),
		calcColor = cloneColor(bgColor or { 0, 0, 0, 1 }),
		show = true,
		defaultTTL = ttl or 1,
		layers = {},
	}, CellLayer)
end

function CellLayer.new(bgColor, ttl)
	return newLayer(bgColor, ttl)
end

function CellLayer:setBackground(color)
	self.bgColor = cloneColor(color or self.bgColor)
	return self
end

function CellLayer:setDefaultTTL(ttl)
	self.defaultTTL = ttl or self.defaultTTL or 1
	return self
end

function CellLayer:show()
	self.show = true
	return self
end

function CellLayer:hide()
	self.show = false
	return self
end

local function logFade(layer, reason)
	if Log.isEnabled("debug") then
		Log.debug(
			"[viz.layers] fade-complete layer=%s reason=%s ttl=%.2f",
			tostring(layer.label or layer.id or "?"),
			reason or "expired",
			layer.ttl or -1
		)
	end
end

function CellLayer:addLayer(opts)
	local key = opts.id or opts.key or tostring(nowSeconds())
	self.layers[key] = {
		id = key,
		color = cloneColor(opts.color),
		ts = opts.ts or nowSeconds(),
		ttl = opts.ttl or self.defaultTTL or 1,
		label = opts.label,
	}
	self.show = (self.show ~= false)
	return self
end

function CellLayer:update(now)
	now = now or nowSeconds()
	local r, g, b, a = self.bgColor[1], self.bgColor[2], self.bgColor[3], self.bgColor[4] or 1
	local active = 0
	for key, layer in pairs(self.layers) do
		local elapsed = now - layer.ts
		if elapsed >= layer.ttl then
			logFade(layer, "expired")
			self.layers[key] = nil
		else
			active = active + 1
			local alpha = 1 - (elapsed / layer.ttl)
			r = layer.color[1] * alpha + r * (1 - alpha)
			g = layer.color[2] * alpha + g * (1 - alpha)
			b = layer.color[3] * alpha + b * (1 - alpha)
		end
	end
	self.calcColor = { r, g, b, a }
	self.activeLayers = active
	return self
end

function CellLayer:getColor()
	if not self.show then
		return nil, nil
	end
	return self.calcColor, self.activeLayers or 0
end

local CompositeCell = {}
CompositeCell.__index = CompositeCell

function CompositeCell.new(opts)
	opts = opts or {}
	-- Explainer: Composite cells bundle the outer fill, every border/gap pair, and
	-- the inner fill so the renderer can treat a grid cell as a single unit.
	-- This is what guarantees we always fade back to the same baseline.
	local self = setmetatable({}, CompositeCell)
	self.ttl = opts.ttl or 1.5
	self.maxLayers = opts.maxLayers or 2
	self.outer = newLayer(opts.gapColor or { 0.12, 0.12, 0.12, 1 }, self.ttl)
	self.borders = {}
	self.gaps = {}
	for i = 1, self.maxLayers do
		self.borders[i] = newLayer(opts.borderColor or { 0.24, 0.24, 0.24, 1 }, self.ttl)
		self.gaps[i] = newLayer(opts.gapColor or { 0.12, 0.12, 0.12, 1 }, self.ttl)
	end
	self.inner = newLayer(opts.innerColor or { 0.2, 0.2, 0.2, 1 }, self.ttl)
	return self
end

function CompositeCell:update(now)
	self.outer:update(now)
	self.inner:update(now)
	for i = 1, self.maxLayers do
		self.borders[i]:update(now)
		self.gaps[i]:update(now)
	end
end

function CompositeCell:getOuter()
	return self.outer
end

function CompositeCell:getBorder(depth)
	return self.borders[depth]
end

function CompositeCell:getGap(depth)
	return self.gaps[depth]
end

function CompositeCell:getInner()
	return self.inner
end

return {
	CellLayer = CellLayer,
	CompositeCell = CompositeCell,
}
