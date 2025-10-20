-- Headless renderer that converts runtime state into a drawable snapshot (no pixels).
-- Useful for tests and trace replay to validate layout/layering logic.
-- The core idea: take every buffered event, map it to a cell (projection key -> grid
-- column/row), blend in the schema color, and keep a "mix weight" that decays over
-- time so cells fade out. Borders represent joins/expirations per layer.

local DEFAULT_INNER_COLOR = { 0.2, 0.2, 0.2, 1 }
local DEFAULT_MATCH_COLOR = { 0.2, 0.85, 0.2, 1 }
local DEFAULT_EXPIRE_COLOR = { 0.9, 0.25, 0.25, 1 }
local NEUTRAL_BORDER_COLOR = { 0.24, 0.24, 0.24, 1 }
local NEUTRAL_GAP_COLOR = { 0.12, 0.12, 0.12, 1 }

local Log = require("log")
local CellLayers = require("viz_high_level.core.cell_layers")
local Renderer = {}
local BACKGROUND_COLOR = { 0.08, 0.08, 0.08, 1 }

-- Utility: accumulate source/match stats for legend + metadata.
local function bumpCount(map, key)
	if not key then
		return
	end
	map[key] = (map[key] or 0) + 1
end

-- Project a logical id (projection key) into a column/row inside the window.
-- We lay out ids column-major: each column spans "rows" ids.
local function mapIdToCell(window, id)
	if not id then
		return nil, nil
	end
	local columns = window.columns or 10
	local rows = window.rows or 10
	local offset = id - window.startId
	if offset < 0 then
		return nil, nil
	end
	local col = math.floor(offset / rows) + 1
	local row = (offset % rows) + 1
	if col < 1 or col > columns or row < 1 or row > rows then
		return nil, nil
	end
	return col, row
end

-- Fetch or create a cell structure for a given column/row.
-- The renderer uses sparse storage so we only keep cells that have data.
local function ensureCell(snapshot, col, row, maxLayers, visualsTTL, createComposite)
	snapshot.cells[col] = snapshot.cells[col] or {}
	local cell = snapshot.cells[col][row]
	if not cell then
		cell = { borders = {} }
		snapshot.cells[col][row] = cell
	end
	if not cell.composite then
		cell.composite = CellLayers.CompositeCell.new({
			maxLayers = maxLayers or 2,
			ttl = visualsTTL or DEFAULT_ADJUST_INTERVAL,
			innerColor = DEFAULT_INNER_COLOR,
			borderColor = NEUTRAL_BORDER_COLOR,
			gapColor = NEUTRAL_GAP_COLOR,
		})
	end
	return cell
end

local function colorForSchema(palette, schema)
	local color = palette and palette[schema]
	if color and color[1] and color[2] and color[3] then
		return color
	end
	return DEFAULT_INNER_COLOR
end

local function colorForKind(palette, kind)
	if kind == "match" then
		return (palette and palette.joined) or DEFAULT_MATCH_COLOR
	end
	return (palette and palette.expired) or DEFAULT_EXPIRE_COLOR
end

local function extractId(event)
	-- Prefer join key so all layers for a join stack on the same cell.
	if event.key ~= nil then
		return event.key
	end
	if event.id ~= nil then
		return event.id
	end
	if event.right and event.right.id ~= nil then
		return event.right.id
	end
	if event.left and event.left.id ~= nil then
		return event.left.id
	end
	if event.schema and event.id ~= nil then
		return event.id
	end
	return nil
end

function Renderer.render(runtime, palette, now)
	assert(runtime and runtime.window, "runtime with window() required")
	local window = runtime:window()
	local visualsTTL = runtime.visualsTTL or runtime.adjustInterval or DEFAULT_ADJUST_INTERVAL
	local currentTime = now or runtime.lastIngestTime or 0
	local snapshot = {
		window = window,
		cells = {},
		meta = {
			renderTime = currentTime,
			sourceCounts = {},
			projectableSourceCounts = {},
			nonProjectableSourceCounts = {},
			matchCount = 0,
			expireCount = 0,
			projectableMatchCount = 0,
			projectableExpireCount = 0,
			maxLayers = runtime.maxLayers or 5,
			palette = palette,
			header = runtime.header or {},
			legend = {},
			outerLegend = {
				{ kind = "match", label = "Joined", color = colorForKind(palette, "match") },
				{ kind = "expire", label = "Expired", color = colorForKind(palette, "expire") },
			},
		},
	}
	snapshot.meta.header.window = window
	snapshot.meta.header.projection = snapshot.meta.header.projection or {}

	-- Inner fills: each projectable source event becomes a colored square tracked by schema/id.
	for _, evt in ipairs(runtime.events.source or {}) do
		local id = evt.projectionKey or evt.id
		local col, row = mapIdToCell(window, id)
		if col and row and evt.projectable then
			local cell = ensureCell(snapshot, col, row, runtime.maxLayers, visualsTTL)
			local innerRegion = cell.composite:getInner()
			innerRegion:setBackground(DEFAULT_INNER_COLOR)
			innerRegion:setDefaultTTL(visualsTTL)
			innerRegion:addLayer({
				color = colorForSchema(palette, evt.schema),
				ts = evt.ingestTime or currentTime,
				id = string.format("%s::%s", tostring(evt.schema), tostring(evt.id)),
				label = evt.schema,
			})
			cell.innerMeta = {
				schema = evt.schema,
				recordId = evt.id,
			}
			bumpCount(snapshot.meta.sourceCounts, evt.schema)
			bumpCount(snapshot.meta.projectableSourceCounts, evt.schema)
		else
			bumpCount(snapshot.meta.sourceCounts, evt.schema)
			bumpCount(snapshot.meta.nonProjectableSourceCounts, evt.schema)
		end
	end

	-- Outer borders: every join result (match layer) gets a border at the proper layer.
	for _, evt in ipairs(runtime.events.match or {}) do
		local id = evt.projectionKey or extractId(evt)
		local col, row = mapIdToCell(window, id)
		if col and row and evt.projectable then
			local cell = ensureCell(snapshot, col, row, runtime.maxLayers, visualsTTL)
			local borderRegion = cell.composite:getBorder(evt.layer)
			if borderRegion then
				borderRegion:setBackground(NEUTRAL_BORDER_COLOR)
				borderRegion:setDefaultTTL(visualsTTL)
				borderRegion:addLayer({
					color = colorForKind(palette, "match"),
					ts = evt.ingestTime or currentTime,
					id = string.format("match_%s_%s", tostring(evt.layer), tostring(id)),
					label = evt.kind or "match",
				})
			end
			cell.borderMeta = cell.borderMeta or {}
			cell.borderMeta[evt.layer] = {
				kind = evt.kind or "match",
				nativeId = (evt.right and evt.right.id) or (evt.left and evt.left.id) or evt.id,
				nativeSchema = (evt.right and evt.right.schema) or (evt.left and evt.left.schema) or evt.schema,
				reason = evt.reason,
			}
			snapshot.meta.matchCount = snapshot.meta.matchCount + 1
			snapshot.meta.projectableMatchCount = snapshot.meta.projectableMatchCount + 1
		else
			snapshot.meta.matchCount = snapshot.meta.matchCount + 1
		end
	end

	-- Expirations also show up as borders (different color) so we can see why cells disappear.
	for _, evt in ipairs(runtime.events.expire or {}) do
		local id = evt.projectionKey or extractId(evt)
		local col, row = mapIdToCell(window, id)
		if col and row and evt.projectable then
			local cell = ensureCell(snapshot, col, row, runtime.maxLayers, visualsTTL)
			local borderRegion = cell.composite:getBorder(evt.layer)
			if borderRegion then
				borderRegion:setBackground(NEUTRAL_BORDER_COLOR)
				borderRegion:setDefaultTTL(visualsTTL)
				borderRegion:addLayer({
					color = colorForKind(palette, "expire"),
					ts = evt.ingestTime or currentTime,
					id = string.format("expire_%s_%s", tostring(evt.layer), tostring(id)),
					label = "expire",
				})
			end
			cell.borderMeta = cell.borderMeta or {}
			cell.borderMeta[evt.layer] = {
				kind = "expire",
				nativeId = evt.id,
				nativeSchema = evt.schema,
				reason = evt.reason,
			}
			snapshot.meta.expireCount = snapshot.meta.expireCount + 1
			snapshot.meta.projectableExpireCount = snapshot.meta.projectableExpireCount + 1
		else
			snapshot.meta.expireCount = snapshot.meta.expireCount + 1
		end
	end

	for _, column in pairs(snapshot.cells) do
		for _, cell in pairs(column) do
			if cell.composite then
				cell.composite:update(currentTime)
			end
		end
	end

	-- Legend: derive from sourceCounts + palette.
	local legendEntries = {}
	for schema, count in pairs(snapshot.meta.sourceCounts) do
		legendEntries[#legendEntries + 1] = {
			schema = schema,
			count = count,
			projectable = snapshot.meta.projectableSourceCounts[schema] or 0,
			nonProjectable = snapshot.meta.nonProjectableSourceCounts[schema] or 0,
			color = colorForSchema(palette, schema),
		}
	end
	snapshot.meta.nonProjectableMatch = snapshot.meta.matchCount - snapshot.meta.projectableMatchCount
	snapshot.meta.nonProjectableExpire = snapshot.meta.expireCount - snapshot.meta.projectableExpireCount
	table.sort(legendEntries, function(a, b)
		return a.schema < b.schema
	end)
	snapshot.meta.legend = legendEntries

	return snapshot
end

return Renderer
