package.path = package.path .. ";../?.lua;../?/init.lua"
package.cpath = package.cpath .. ";../?.so"

require("bootstrap")

local DataSources = require("viz.sources")
local PreRender = require("pre_render")
local rx = require("reactivex")

local gridConfig = DataSources.grid or {}
local GRID_COLUMNS = gridConfig.columns or 32
local GRID_ROWS = gridConfig.rows or 32
local CELL_SIZE = gridConfig.cellSize or 26
local CELL_PADDING = gridConfig.padding or 3
local DEFAULT_COLOR = { 0.2, 0.2, 0.2, 1 }
local FADE_DURATION_SECONDS = DataSources.fadeDurationSeconds or 10
local INNER_INSET = 4

local cells = { inner = {}, outer = {} }
local hover = nil
local innerState = nil
local outerState = nil
local needsRefresh = true

local function clampComponent(value)
	return math.max(0, math.min(1, value or 0))
end

local function normalizeColor(color)
	return {
		clampComponent(color[1]),
		clampComponent(color[2]),
		clampComponent(color[3]),
		color[4] and clampComponent(color[4]) or 1,
	}
end

local function normalizeLayer(layer)
	if layer == "outer" then
		return "outer"
	end
	return "inner"
end

local function ensureLayerTable(layer)
	layer = normalizeLayer(layer)
	cells[layer] = cells[layer] or {}
	return cells[layer]
end

local function ensureCell(layer, col, row)
	local grid = ensureLayerTable(layer)
	grid[col] = grid[col] or {}
	grid[col][row] = grid[col][row] or { color = DEFAULT_COLOR, text = nil, meta = nil }
	return grid[col][row]
end

local StreamGrid = {}

local function resolveArgs(a, b, c, d)
	if type(a) == "string" then
		return normalizeLayer(a), b, c, d
	end
	return "inner", a, b, c
end

function StreamGrid.setCell(a, b, c, d)
	local layer, col, row, opts = resolveArgs(a, b, c, d)
	if col < 1 or col > GRID_COLUMNS or row < 1 or row > GRID_ROWS then
		return nil, "out_of_bounds"
	end
	local cell = ensureCell(layer, col, row)
	if opts and opts.color then
		cell.color = normalizeColor(opts.color)
	end
	if opts and opts.text ~= nil then
		cell.text = opts.text
	end
	if opts and opts.meta ~= nil then
		cell.meta = opts.meta
	end
	return cell
end

function StreamGrid.get(a, b, c)
	local layer, col, row = resolveArgs(a, b, c)
	local grid = cells[layer]
	return grid and grid[col] and grid[col][row] or nil
end

function StreamGrid.clear(layer)
	if layer then
		layer = normalizeLayer(layer)
		cells[layer] = {}
	else
		cells.inner = {}
		cells.outer = {}
	end
end

_G.StreamGrid = StreamGrid

local function cellAtPixel(x, y)
	local col = math.floor(x / CELL_SIZE) + 1
	local row = math.floor(y / CELL_SIZE) + 1
	if col < 1 or col > GRID_COLUMNS or row < 1 or row > GRID_ROWS then
		return nil, nil
	end
	return col, row
end

local function mixWithBackground(color, alpha)
	local weight = clampComponent((alpha or 0) / 100)
	local bg = DEFAULT_COLOR
	color = color or DEFAULT_COLOR
	return {
		bg[1] + (color[1] - bg[1]) * weight,
		bg[2] + (color[2] - bg[2]) * weight,
		bg[3] + (color[3] - bg[3]) * weight,
		1,
	}
end

local function summarizeRecord(record)
	if type(record) ~= "table" then
		return tostring(record)
	end
	local fragments = {}
	local count = 0
	for key, value in pairs(record) do
		if key ~= "RxMeta" then
			count = count + 1
			if count > 10 then
				fragments[#fragments + 1] = "..."
				break
			end
			fragments[#fragments + 1] = string.format("%s=%s", key, tostring(value))
		end
	end
	if #fragments == 0 then
		return "{}"
	end
	return "{" .. table.concat(fragments, ", ") .. "}"
end

local function populateLayer(layer, state)
	if not state then
		return
	end
	StreamGrid.clear(layer)
	state:forEachInOrder(function(entry, col, row)
		local sourceMeta = entry.meta
		local meta = {
			id = entry.id,
			layer = layer,
			alpha = entry.alpha,
			sources = entry.sources,
			match = sourceMeta and sourceMeta.match or nil,
			expired = sourceMeta and sourceMeta.expired or nil,
			schema = sourceMeta and sourceMeta.schema or nil,
			customer = sourceMeta and sourceMeta.customer or nil,
			order = sourceMeta and sourceMeta.order or nil,
			record = sourceMeta and (sourceMeta.record or (not sourceMeta.customer and not sourceMeta.order and sourceMeta)) or nil,
		}
		if not meta.schema and meta.record and meta.record.schema then
			meta.schema = meta.record.schema
		end
		local cell = StreamGrid.setCell(layer, col, row, {
			color = mixWithBackground(entry.color, entry.alpha),
			meta = meta,
		})
		if not cell then
			return true
		end
	end)
end

function love.load()
	local width = GRID_COLUMNS * CELL_SIZE
	local height = GRID_ROWS * CELL_SIZE + 40
	love.window.setMode(width, height, { resizable = false })
	love.graphics.setFont(love.graphics.newFont(14))
	innerState, outerState = PreRender.buildDemoStates({
		columns = GRID_COLUMNS,
		rows = GRID_ROWS,
		fadeDuration = FADE_DURATION_SECONDS,
	})
	populateLayer("inner", innerState)
	populateLayer("outer", outerState)
	needsRefresh = false
end

function love.update(dt)
	if innerState then
		innerState:advance(dt)
		needsRefresh = true
	end
	if outerState then
		outerState:advance(dt)
		needsRefresh = true
	end
	if dt and dt > 0 then
		rx.scheduler.update(dt)
	end
	if needsRefresh then
		populateLayer("inner", innerState)
		populateLayer("outer", outerState)
		needsRefresh = false
	end
end

function love.mousemoved(x, y)
	local col, row = cellAtPixel(x, y)
	if col and row then
		hover = { col = col, row = row }
	else
		hover = nil
	end
end

function love.draw()
	love.graphics.clear(0.1, 0.1, 0.1)

	for col = 1, GRID_COLUMNS do
		for row = 1, GRID_ROWS do
			local outerCell = StreamGrid.get("outer", col, row)
			local innerCell = StreamGrid.get("inner", col, row)
			local outerColor = outerCell and outerCell.color or DEFAULT_COLOR
			local innerColor = innerCell and innerCell.color or nil
			local x = (col - 1) * CELL_SIZE + CELL_PADDING
			local y = (row - 1) * CELL_SIZE + CELL_PADDING
			local outerSize = CELL_SIZE - CELL_PADDING * 2
			local innerSize = outerSize - INNER_INSET * 2
			if innerSize < 2 then
				innerSize = math.max(1, outerSize * 0.6)
			end

			love.graphics.setColor(outerColor)
			love.graphics.rectangle("fill", x, y, outerSize, outerSize)

			if innerColor then
				love.graphics.setColor(innerColor)
				love.graphics.rectangle("fill", x + INNER_INSET, y + INNER_INSET, innerSize, innerSize)
			end

			if hover and hover.col == col and hover.row == row then
				love.graphics.setColor(1, 1, 1, 0.7)
				love.graphics.rectangle("line", x, y, outerSize, outerSize)
			end
		end
	end

	if hover then
		local innerCell = StreamGrid.get("inner", hover.col, hover.row)
		local outerCell = StreamGrid.get("outer", hover.col, hover.row)
		local meta = outerCell and outerCell.meta or innerCell and innerCell.meta or nil
		local label = string.format("Cell (%d,%d)", hover.col, hover.row)
		if meta then
			local parts = {}
			if meta.match then
				parts[#parts + 1] = "Match"
			elseif meta.expired then
				parts[#parts + 1] = "Expire"
			end
			if meta.schema then
				parts[#parts + 1] = "schema=" .. tostring(meta.schema)
			end
			if meta.customer then
				parts[#parts + 1] = "customer=" .. summarizeRecord(meta.customer)
			end
			if meta.order then
				parts[#parts + 1] = "order=" .. summarizeRecord(meta.order)
			end
			if meta.record then
				parts[#parts + 1] = "record=" .. summarizeRecord(meta.record)
			end
			parts[#parts + 1] = "id=" .. tostring(meta.id)
			if #parts > 0 then
				label = label .. ": " .. table.concat(parts, " ")
			end
		end
		love.graphics.setColor(1, 1, 1, 1)
		local textX = 10
		local textY = GRID_ROWS * CELL_SIZE + 12
		love.graphics.print(label, textX, textY)
	end
end
