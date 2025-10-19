-- Drawing helpers for high-level viz snapshots.
local Draw = {}

local SMALL_CELL_SIZE = 26
local LARGE_CELL_SIZE = 8
local CELL_PADDING = 3
local INNER_INSET = 4
local BACKGROUND = { 0.1, 0.1, 0.1, 1 }
local EMPTY_CELL_COLOR = { 0.2, 0.2, 0.2, 1 }
local BORDER_COLORS = {
	match = { 0, 1, 0, 1 },
	expire = { 1, 0, 0, 1 },
}
local ROW_LABEL_WIDTH = 40
local COLUMN_LABEL_HEIGHT = 18

local function metricsForWindow(window)
	local columns = window.columns or 10
	local rows = window.rows or 10
	local cellSize = columns > 10 and LARGE_CELL_SIZE or SMALL_CELL_SIZE
	return {
		cellSize = cellSize,
		width = columns * cellSize,
		height = rows * cellSize,
		columns = columns,
		rows = rows,
		rowLabelWidth = ROW_LABEL_WIDTH,
		columnLabelHeight = COLUMN_LABEL_HEIGHT,
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

local function drawCell(col, row, cell, metrics)
	cell = cell or { borders = {} }
	local size = metrics.cellSize - CELL_PADDING * 2
	local x = (col - 1) * metrics.cellSize + CELL_PADDING
	local y = (row - 1) * metrics.cellSize + CELL_PADDING
	rect(x, y, size, BACKGROUND, nil, "fill")
	-- Inner fill
	if cell.inner and cell.inner.color then
		local innerSize = size - INNER_INSET * 2
		innerSize = math.max(4, innerSize)
		local inset = INNER_INSET
		local color = cell.inner.color
		local intensity = math.min(math.max(cell.inner.intensity or color[4] or 1, 0), 1)
		local mixedColor = {
			EMPTY_CELL_COLOR[1] * (1 - intensity) + color[1] * intensity,
			EMPTY_CELL_COLOR[2] * (1 - intensity) + color[2] * intensity,
			EMPTY_CELL_COLOR[3] * (1 - intensity) + color[3] * intensity,
			1,
		}
		rect(
			x + inset,
			y + inset,
			innerSize,
			mixedColor,
			nil,
			"fill"
		)
	else
		local innerSize = size - INNER_INSET * 2
		innerSize = math.max(4, innerSize)
		local inset = INNER_INSET
		rect(x + inset, y + inset, innerSize, EMPTY_CELL_COLOR, nil, "fill")
		rect(x + inset, y + inset, innerSize, { 0.3, 0.3, 0.3, 0.6 }, 1, "line")
	end

	-- Layered borders (outermost = layer 1), sorted for deterministic drawing.
	local layers = {}
	for layer in pairs(cell.borders or {}) do
		layers[#layers + 1] = layer
		layers[#layers] = tonumber(layers[#layers]) or layers[#layers]
	end
	table.sort(layers)
	for _, layer in ipairs(layers) do
		local border = cell.borders[layer]
		local lineSize = 2
		local inset = (layer - 1) * 3
		local borderSize = size - inset * 2
		if borderSize < 2 then
			borderSize = 2
		end
		local baseColor = border.color or BORDER_COLORS[border.kind] or { 1, 1, 1, 1 }
		local alpha = border.opacity or baseColor[4] or 1
		rect(
			x + inset,
			y + inset,
			borderSize,
			{ baseColor[1], baseColor[2], baseColor[3], alpha },
			lineSize,
			"line"
		)
	end
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
	local metrics = metricsForWindow(window)
	for col = 1, metrics.columns do
		for row = 1, metrics.rows do
			local cell = snapshot.cells[col] and snapshot.cells[col][row]
			drawCell(col, row, cell, metrics)
		end
	end
	if opts and opts.showLabels then
		lg.setColor(1, 1, 1, 1)
		for col = 1, metrics.columns do
			local colText = columnLabel(window, col)
			lg.printf(colText, (col - 1) * metrics.cellSize, -COLUMN_LABEL_HEIGHT, metrics.cellSize, "center")
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
	if not window then
		return { cellSize = SMALL_CELL_SIZE, width = SMALL_CELL_SIZE * 10, height = SMALL_CELL_SIZE * 10 }
	end
	return metricsForWindow(window)
end

return Draw
