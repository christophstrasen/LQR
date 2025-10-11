require("bootstrap")

local ScenarioLoader = require("viz.scenario_loader")
local Observables = require("viz.observables")
local DataSources = ScenarioLoader.getRecipe(Observables)
local PreRender = require("pre_render")
local rx = require("reactivex")

local windowConfig = DataSources.window or {}
local gridConfig = windowConfig.grid or {}
local GRID_COLUMNS = gridConfig.columns or 32
local GRID_ROWS = gridConfig.rows or 32
local CELL_SIZE = gridConfig.cellSize or 26
local CELL_PADDING = gridConfig.padding or 3
local DEFAULT_COLOR = { 0.2, 0.2, 0.2, 1 }
local FADE_DURATION_SECONDS = windowConfig.fadeSeconds or 10
local HEADER_HEIGHT = 200
local GRID_TOP = HEADER_HEIGHT
local INNER_INSET = 4
local HOVER_PANEL_HEIGHT = 120
local WINDOW_WIDTH = GRID_COLUMNS * CELL_SIZE
local WINDOW_HEIGHT = HEADER_HEIGHT + GRID_ROWS * CELL_SIZE + HOVER_PANEL_HEIGHT

local layerStatesByName = {}
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
	if type(layer) == "string" and layer ~= "" then
		return layer
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
		return
	end
	for name in pairs(cells) do
		cells[name] = {}
	end
end

_G.StreamGrid = StreamGrid

local function cellAtPixel(x, y)
	if y < GRID_TOP then
		return nil, nil
	end
	local col = math.floor(x / CELL_SIZE) + 1
	local row = math.floor((y - GRID_TOP) / CELL_SIZE) + 1
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

local function copyTable(source)
	if type(source) ~= "table" then
		return {}
	end
	local copy = {}
	for key, value in pairs(source) do
		copy[key] = value
	end
	return copy
end

local function populateLayer(layer, state)
	if not state then
		return
	end
	StreamGrid.clear(layer)
	state:forEachInOrder(function(entry, col, row)
		local meta = copyTable(entry.meta)
		meta.id = meta.id or entry.id
		meta.layer = layer
		meta.alpha = entry.alpha
		meta.sources = entry.sources
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
	love.window.setMode(WINDOW_WIDTH, WINDOW_HEIGHT, { resizable = false })
	love.graphics.setFont(love.graphics.newFont(14))
	local states
	innerState, outerState, states = PreRender.buildDemoStates({
		columns = GRID_COLUMNS,
		rows = GRID_ROWS,
		fadeDuration = FADE_DURATION_SECONDS,
	})
	layerStatesByName = states or {}
	for name, state in pairs(layerStatesByName) do
		cells[name] = cells[name] or {}
		populateLayer(name, state)
	end
	needsRefresh = false
end

function love.update(dt)
	local advanced = false
	if dt and dt > 0 then
		for _, state in pairs(layerStatesByName or {}) do
			if state and state.advance then
				state:advance(dt)
				advanced = true
			end
		end
		rx.scheduler.update(dt)
	end
	if advanced then
		needsRefresh = true
	end
	if needsRefresh then
		for name, state in pairs(layerStatesByName or {}) do
			populateLayer(name, state)
		end
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

	local headerText = windowConfig.headerText
	if not headerText then
		local joins = ScenarioLoader.data and ScenarioLoader.data.joins
		local join = joins and joins[1] or (ScenarioLoader.data and ScenarioLoader.data.join)
		if join then
			local sources = join.sources or {}
			local leftSchema = join.left or sources.left or "left"
			local rightSchema = join.right or sources.right or "right"
			local on = join.on or {}
			local function describeKey(schemaName)
				local selector = on[schemaName]
				if type(selector) == "string" then
					return selector
				elseif type(selector) == "table" then
					return selector.field or (selector.selector and "<fn>") or tostring(selector)
				elseif type(selector) == "function" then
					return "<fn>"
				end
				return "id"
			end
			local startOffset = gridConfig.startOffset or windowConfig.startOffset or windowConfig.minId
			local rangeText = ""
			if startOffset ~= nil then
				local totalCells = GRID_COLUMNS * GRID_ROWS
				local rangeEnd = startOffset + totalCells - 1
				rangeText = string.format(
					"Showing records on id range %s-%s (grid %dx%d). ",
					tostring(startOffset),
					tostring(rangeEnd),
					GRID_COLUMNS,
					GRID_ROWS
				)
			else
				rangeText = string.format("Showing records on grid %dx%d. ", GRID_COLUMNS, GRID_ROWS)
			end
			headerText = string.format(
				"%s%s join on %s.%s, %s.%s",
				rangeText,
				(join.joinType or "inner"),
				leftSchema,
				describeKey(leftSchema),
				rightSchema,
				describeKey(rightSchema)
			)
		end
	end

	love.graphics.setColor(0.05, 0.05, 0.05, 0.9)
	love.graphics.rectangle("fill", 0, 0, WINDOW_WIDTH, HEADER_HEIGHT)
	love.graphics.setColor(1, 1, 1, 1)
	if headerText then
		love.graphics.printf(headerText, 12, 10, WINDOW_WIDTH - 24)
	end

	local function drawLegendRow(y, color, label, count, opts)
		opts = opts or {}
		local layoutSize = math.max(16, CELL_SIZE - CELL_PADDING * 2)
		local innerSize = layoutSize - INNER_INSET * 2
		if innerSize < 2 then
			innerSize = math.max(1, layoutSize * 0.6)
		end
		local rectSize = layoutSize
		local x = 12
		local textX = x + rectSize + 8
		local countText = count ~= nil and string.format("%dx", count) or "n/a"
		love.graphics.printf(countText, x, y, 60, "left")
		x = x + 50
		textX = x + rectSize + 8
		if color then
			if opts.outerBox then
				love.graphics.setColor(color)
				love.graphics.rectangle("fill", x, y, rectSize, rectSize)
				local insetOffset = (rectSize - innerSize) / 2
				love.graphics.setColor(DEFAULT_COLOR)
				love.graphics.rectangle("fill", x + insetOffset, y + insetOffset, innerSize, innerSize)
			else
				local insetOffset = (rectSize - innerSize) / 2
				love.graphics.setColor(color)
				love.graphics.rectangle("fill", x + insetOffset, y + insetOffset, innerSize, innerSize)
			end
			love.graphics.setColor(1, 1, 1, 1)
		end
		love.graphics.printf(label, textX, y, WINDOW_WIDTH - textX - 12, "left")
	end

	local palette = (innerState or {}).palette or windowConfig.colors or {}
	local innerStreams = (windowConfig.layers and windowConfig.layers.inner and windowConfig.layers.inner.streams) or {}
	local yOffset = 52
	for _, stream in ipairs(innerStreams) do
		local name = stream.name or stream.paletteKey
		if name then
			local trackField = stream.track_field
				or stream.trackField
				or (stream.tracks and stream.tracks[1] and stream.tracks[1].field)
				or "id"
			local label = string.format("%s.%s", name, trackField)
			local count = innerState and innerState.getCount and innerState:getCount(name) or 0
			drawLegendRow(yOffset, palette[name], label, count)
			yOffset = yOffset + 28
		end
	end

	local outerPalette = windowConfig.colors or palette
	local joinedColor = outerPalette.joined or DEFAULT_COLOR
	local expiredColor = outerPalette.expired or DEFAULT_COLOR

	local joinedCount = outerState and outerState.getCount and outerState:getCount("joined") or 0
	local expiredCount = outerState and outerState.getCount and outerState:getCount("expired") or 0

	drawLegendRow(yOffset, joinedColor, "Joined", joinedCount, { outerBox = true })
	yOffset = yOffset + 28
	drawLegendRow(yOffset, expiredColor, "Expired", expiredCount, { outerBox = true })
	yOffset = yOffset + 28

	local mixed = {
		(joinedColor[1] + expiredColor[1]) / 2,
		(joinedColor[2] + expiredColor[2]) / 2,
		(joinedColor[3] + expiredColor[3]) / 2,
		1,
	}
	drawLegendRow(
		yOffset,
		mixed,
		"Join when expired. Color indicates mix when joined and expired arrive close together.",
		nil,
		{ outerBox = true }
	)
	yOffset = yOffset + 28

	for col = 1, GRID_COLUMNS do
		for row = 1, GRID_ROWS do
			local outerCell = StreamGrid.get("outer", col, row)
			local innerCell = StreamGrid.get("inner", col, row)
			local outerColor = outerCell and outerCell.color or DEFAULT_COLOR
			local innerColor = innerCell and innerCell.color or nil
			local x = (col - 1) * CELL_SIZE + CELL_PADDING
			local y = GRID_TOP + (row - 1) * CELL_SIZE + CELL_PADDING
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
			if meta.label then
				parts[#parts + 1] = tostring(meta.label)
			end
			local hoverInfo = meta.hover
			local function appendPair(key, value)
				if value ~= nil then
					if type(value) == "table" then
						value = summarizeRecord(value)
					elseif type(value) == "boolean" then
						value = value and "true" or "false"
					else
						value = tostring(value)
					end
					parts[#parts + 1] = string.format("%s=%s", key, value)
				end
			end
			if type(hoverInfo) == "table" then
				for key, value in pairs(hoverInfo) do
					appendPair(key, value)
				end
			else
				for key, value in pairs(meta) do
					if key ~= "label" and key ~= "hover" and key ~= "layer" and key ~= "alpha" and key ~= "sources" then
						appendPair(key, value)
					end
				end
			end
			appendPair("id", meta.id)
			if #parts > 0 then
				label = label .. "\n" .. table.concat(parts, "\n")
			end
			if meta.sourceTime then
				local fractional = meta.sourceTime
				local seconds = math.floor(fractional)
				local millis = math.floor((fractional - seconds) * 1000)
				local timestamp = os.date("%Y-%m-%d %H:%M:%S", seconds)
				local ts = string.format("timestamp=%s.%03d", timestamp, millis)
				parts[#parts + 1] = ts
				label = label .. "\n" .. ts
			end
		end
		local panelY = GRID_TOP + GRID_ROWS * CELL_SIZE
		love.graphics.setColor(0.05, 0.05, 0.05, 0.9)
		love.graphics.rectangle("fill", 0, panelY, WINDOW_WIDTH, HOVER_PANEL_HEIGHT)
		love.graphics.setColor(1, 1, 1, 1)
		local textX = 12
		local textY = panelY + 12
		local textWidth = WINDOW_WIDTH - textX * 2
		love.graphics.printf(label, textX, textY, textWidth)
	end
end
