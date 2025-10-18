-- Drawing helpers for high-level viz snapshots.
local Draw = {}

local CELL_SIZE = 26
local CELL_PADDING = 3
local INNER_INSET = 4
local BACKGROUND = { 0.1, 0.1, 0.1, 1 }
local BORDER_COLORS = {
	match = { 0, 1, 0, 1 },
	expire = { 1, 0, 0, 1 },
}

local function rect(x, y, size, color, lineWidth, mode)
	local lg = love.graphics
	lg.setColor(color)
	mode = mode or "fill"
	if mode == "line" and lineWidth then
		lg.setLineWidth(lineWidth)
	end
	lg.rectangle(mode, x, y, size, size)
end

local function drawCell(col, row, cell)
	local size = CELL_SIZE - CELL_PADDING * 2
	local x = (col - 1) * CELL_SIZE + CELL_PADDING
	local y = (row - 1) * CELL_SIZE + CELL_PADDING

	-- Inner fill
	if cell.inner and cell.inner.color then
		local innerSize = size - INNER_INSET * 2
		innerSize = math.max(4, innerSize)
		local inset = INNER_INSET
		rect(x + inset, y + inset, innerSize, cell.inner.color, nil, "fill")
	else
		rect(x, y, size, BACKGROUND, nil, "fill")
	end

	-- Layered borders (outermost = layer 1)
	for layer, border in pairs(cell.borders or {}) do
		local lineSize = 1 + (layer - 1)
		local inset = lineSize
		local borderSize = size - inset * 2
		local color = border.color or BORDER_COLORS[border.kind] or { 1, 1, 1, 1 }
		rect(x + inset, y + inset, borderSize, color, lineSize, "line")
	end
end

---Draws a snapshot at the current origin.
---@param snapshot table from headless_renderer.render
function Draw.drawSnapshot(snapshot)
	if not snapshot or not snapshot.cells then
		return
	end
	local lg = love.graphics
	lg.push()
	for col, colCells in pairs(snapshot.cells) do
		for row, cell in pairs(colCells) do
			drawCell(col, row, cell)
		end
	end
	lg.pop()
end

return Draw
