-- Drawing helpers for high-level viz snapshots.
local Draw = {}
local CellLayers = require("viz_high_level.core.cell_layers")

local SMALL_LAYOUT = {
	padding = 3,
	outerInset = 1,
	innerOutline = 2,
	innerSize = 16,
	borderThickness = 2,
	gapThickness = 1,
}
local LARGE_LAYOUT = {
	padding = 1,
	outerInset = 1,
	innerOutline = 1,
	innerSize = 5,
	borderThickness = 1,
	gapThickness = 1,
}
local BACKGROUND = { 0.1, 0.1, 0.1, 1 }
local EMPTY_CELL_COLOR = { 0.2, 0.2, 0.2, 1 }
local OUTER_BASE_COLOR = { 0.24, 0.24, 0.24, 1 }
local OUTER_SHADOW_COLOR = { 0.12, 0.12, 0.12, 1 }
local NEUTRAL_BORDER_COLOR = OUTER_BASE_COLOR
local BORDER_COLORS = {
	match = { 0, 1, 0, 1 },
	expire = { 1, 0, 0, 1 },
}
local ROW_LABEL_WIDTH = 40
local COLUMN_LABEL_HEIGHT = 18
local COLUMN_LABEL_GAP = 10

local function clamp01(value)
	if value < 0 then
		return 0
	end
	if value > 1 then
		return 1
	end
	return value
end

local function lerpColor(from, to, factor)
	factor = clamp01(factor or 1)
	local inv = 1 - factor
	local src = from or to
	return {
		(src[1] or 0) * factor + (to[1] or 0) * inv,
		(src[2] or 0) * factor + (to[2] or 0) * inv,
		(src[3] or 0) * factor + (to[3] or 0) * inv,
		(src[4] or 1) * factor + (to[4] or 1) * inv,
	}
end

local function metricsForWindow(window, layersBudget)
	local columns = window.columns or 10
	local rows = window.rows or 10
	local useLarge = columns > 10
	local layout = useLarge and LARGE_LAYOUT or SMALL_LAYOUT
	local layers = math.max(layersBudget or 0, 0)
	local layerThickness = layout.borderThickness + layout.gapThickness
	local contentSize = layout.innerSize + (2 * layers * layerThickness)
	local cellSize = contentSize + (layout.outerInset * 2) + (layout.padding * 2)
	return {
		cellSize = cellSize,
		contentSize = contentSize,
		layerThickness = layerThickness,
		layersBudget = layers,
		width = columns * cellSize,
		height = rows * cellSize,
		columns = columns,
		rows = rows,
		rowLabelWidth = ROW_LABEL_WIDTH,
		columnLabelHeight = COLUMN_LABEL_HEIGHT,
		padding = layout.padding,
		outerInset = layout.outerInset,
		borderThickness = layout.borderThickness,
		gapThickness = layout.gapThickness,
		innerSize = layout.innerSize,
		innerOutline = layout.innerOutline,
	}
end

local function rect(x, y, size, color, lineWidth, mode)
	local lg = love.graphics
	lg.setColor(color)
	mode = mode or "fill"
	if mode == "line" and lineWidth then
		lg.setLineWidth(lineWidth)
	end
	lg.rectangle(mode, x, y, size, size)
end

local function regionColor(region, fallback)
	if not region then
		return fallback
	end
	local color = select(1, region:getColor())
	return color or fallback
end

local function drawCell(col, row, cell, metrics, renderTime, maxLayers, joinCount)
	local composite = cell and cell.composite
	if not composite then
		-- Explainer: even empty cells get a composite at draw time so the visuals
		-- stay consistent after zoom shifts—every region fades the same way.
		composite = CellLayers.CompositeCell.new({
			maxLayers = maxLayers or 1,
		})
	end
	local padding = metrics.padding or 0
	local baseSize = metrics.contentSize or (metrics.cellSize - padding * 2)
	local x = (col - 1) * metrics.cellSize + padding
	local y = (row - 1) * metrics.cellSize + padding
	composite:update(renderTime)
	local outerInset = metrics.outerInset or 0
	local currentInset = outerInset
	local currentSize = baseSize
	if currentSize <= 0 then
		return
	end
	local outerColor = regionColor(composite:getOuter(), NEUTRAL_GAP_COLOR)
	rect(x + currentInset, y + currentInset, currentSize, outerColor, nil, "fill")
	local joins = joinCount or 0
	local layersBudget = math.max(metrics.layersBudget or 0, 0)
	local layerThickness = metrics.layerThickness or ((metrics.borderThickness or 1) + (metrics.gapThickness or 1))
	local layersToDraw = math.min(joins, maxLayers or 0, composite.maxLayers or 0)
	layersToDraw = math.min(layersToDraw, layersBudget)
	local unusedLayers = math.max(layersBudget - layersToDraw, 0)
	if unusedLayers > 0 then
		local skip = unusedLayers * layerThickness
		currentInset = currentInset + skip
		currentSize = currentSize - (skip * 2)
	end
	if currentSize <= 0 then
		return
	end
	local borderThickness = metrics.borderThickness or 1
	local gapThickness = metrics.gapThickness or 1
	for depth = 1, layersToDraw do
		local borderRegion = composite:getBorder(depth)
		local gapRegion = composite:getGap(depth)
		local borderColor = regionColor(borderRegion, NEUTRAL_BORDER_COLOR)
		rect(x + currentInset, y + currentInset, currentSize, borderColor, nil, "fill")
		currentInset = currentInset + borderThickness
		currentSize = currentSize - borderThickness * 2
		if currentSize <= 0 then
			break
		end
		local gapColor = regionColor(gapRegion, NEUTRAL_GAP_COLOR)
		rect(x + currentInset, y + currentInset, currentSize, gapColor, nil, "fill")
		currentInset = currentInset + gapThickness
		currentSize = currentSize - gapThickness * 2
		if currentSize <= 0 then
			break
		end
	end
	if currentSize <= 0 then
		return
	end
	local innerColor = regionColor(composite:getInner(), EMPTY_CELL_COLOR)
	rect(x + currentInset, y + currentInset, currentSize, innerColor, nil, "fill")
	local outline = metrics.innerOutline or 1
	rect(x + currentInset, y + currentInset, currentSize, { 0.3, 0.3, 0.3, 0.6 }, outline, "line")
end

local function columnLabel(window, col)
	local rowBase = window.rows or 10
	local baseCol = math.floor(window.startId / rowBase) + (col - 1)
	return tostring(baseCol)
end

local function rowLabel(window, row)
	local rowDigits = (window.rows or 10) >= 100 and 2 or 1
	local rowVal = (row - 1) % (10 ^ rowDigits)
	local formatStr = "%0" .. tostring(rowDigits) .. "d"
	return string.format(formatStr, rowVal)
end

---Draws a snapshot at the current origin.
---@param snapshot table from headless_renderer.render
---@param opts table|nil
function Draw.drawSnapshot(snapshot, opts)
	if not snapshot or not snapshot.cells then
		return
	end
	local lg = love.graphics
	lg.push()
	local window = snapshot.window or (snapshot.meta and snapshot.meta.header and snapshot.meta.header.window)
	if not window then
		lg.pop()
		return
	end
	local meta = snapshot.meta or {}
	local maxLayers = meta.maxLayers or 1
	local joinCount = #(meta.header and meta.header.joins or {})
	local layerBudget = math.min(joinCount, maxLayers)
	local metrics = metricsForWindow(window, layerBudget)
	local renderTime = meta.renderTime or (love and love.timer and love.timer.getTime()) or os.clock()
	for col = 1, metrics.columns do
		for row = 1, metrics.rows do
			local cell = snapshot.cells[col] and snapshot.cells[col][row]
			drawCell(col, row, cell, metrics, renderTime, maxLayers, joinCount)
		end
	end
	if opts and opts.showLabels then
		lg.setColor(1, 1, 1, 1)
		for col = 1, metrics.columns do
			local colText = columnLabel(window, col)
			lg.printf(
				colText,
				(col - 1) * metrics.cellSize,
				-(COLUMN_LABEL_HEIGHT + COLUMN_LABEL_GAP),
				metrics.cellSize,
				"center"
			)
		end
		for row = 1, metrics.rows do
			local rowText = rowLabel(window, row)
			lg.printf(rowText, -ROW_LABEL_WIDTH, (row - 1) * metrics.cellSize, ROW_LABEL_WIDTH - 4, "right")
		end
	end
	lg.pop()
end

function Draw.metrics(snapshot)
	local window = snapshot.window or (snapshot.meta and snapshot.meta.header and snapshot.meta.header.window)
	local meta = snapshot.meta or {}
	local maxLayers = meta.maxLayers or 1
	local joinCount = #(meta.header and meta.header.joins or {})
	local layerBudget = math.min(joinCount, maxLayers)
	window = window or { columns = 10, rows = 10 }
	return metricsForWindow(window, layerBudget)
end

return Draw
