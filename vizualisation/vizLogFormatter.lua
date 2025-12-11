-- Snapshot formatter for high-level visualization: logs cells/borders/metadata with a dedicated tag.
local Log = require("LQR/util/log")
local CellLayers = require("vizualisation/core/cell_layers")

local VizLog = Log.withTag("viz-hi")
local NEUTRAL_BORDER_COLOR = { 0.24, 0.24, 0.24, 1 }
local lastSignature
local seenCells = {}
local lastWindowSignature

local VizLogFormatter = {}

local function logAt(level, fmt, ...)
	if not Log.isEnabled(level, "viz-hi") then
		return
	end
	VizLog:log(level, fmt, ...)
end

local function collectCells(snapshot)
	local cells = {}
	for colIndex, column in pairs(snapshot.cells or {}) do
		for rowIndex, cell in pairs(column or {}) do
			cells[#cells + 1] = {
				col = tonumber(colIndex) or colIndex,
				row = tonumber(rowIndex) or rowIndex,
				cell = cell,
			}
		end
	end
	table.sort(cells, function(a, b)
		if a.col == b.col then
			return a.row < b.row
		end
		return a.col < b.col
	end)
	return cells
end

local function formatColor(color)
	if not color then
		return "0.00,0.00,0.00"
	end
	return string.format("%.2f,%.2f,%.2f", color[1] or 0, color[2] or 0, color[3] or 0)
end

local function idForCell(window, col, row)
	local rows = window.rows or 10
	local base = window.startId or 0
	return base + (col - 1) * rows + (row - 1)
end

local function snapshotSignature(snapshot, cells)
	local window = snapshot.window or {}
	local parts = {
		string.format("%s:%s:%s:%s", tostring(window.startId), tostring(window.endId), tostring(window.columns), tostring(window.rows)),
	}
	for _, entry in ipairs(cells) do
		local cell = entry.cell or {}
		if cell.composite then
			local meta = cell.innerMeta or {}
			local innerRegion = cell.composite:getInner()
			local _, layers = innerRegion and innerRegion:getColor()
			parts[#parts + 1] = table.concat({
				"I",
				entry.col,
				entry.row,
				tostring(meta.schema),
				tostring(meta.recordId),
				string.format("%.2f", layers or 0),
			}, ":")
		end
		local layers = {}
		for layer in pairs(cell.borderMeta or {}) do
			layers[#layers + 1] = layer
		end
		table.sort(layers)
		for _, layer in ipairs(layers) do
			local border = cell.borderMeta[layer]
			parts[#parts + 1] = table.concat({
				"B",
				entry.col,
				entry.row,
				layer,
				border and border.kind or "match",
				border and tostring(border.nativeSchema) or "",
				border and tostring(border.nativeId) or "",
			}, ":")
		end
	end
	return table.concat(parts, "|")
end

local function windowSignature(window)
	if not window then
		return ""
	end
	return string.format("%s:%s:%s:%s", tostring(window.startId), tostring(window.endId), tostring(window.columns), tostring(window.rows))
end

local function cellKey(window, entry, id)
	return string.format(
		"%s:%s:%s:%s",
		tostring(window and window.startId),
		tostring(entry.col),
		tostring(entry.row),
		tostring(id)
	)
end

---Logs detailed cell/border information for a snapshot when debug/info logging is enabled for viz-debug.
---@param snapshot table
---@param opts table|nil
function VizLogFormatter.snapshot(snapshot, opts)
	opts = opts or {}
	-- Only log snapshots when explicitly requested (e.g., headless renderers set logSnapshots=true).
	if not opts.logSnapshots then
		return
	end
	if not (Log.isEnabled("debug", "viz-hi") or Log.isEnabled("info", "viz-hi")) then
		return
	end
	if not snapshot or not snapshot.window then
		return
	end
	local cells = collectCells(snapshot)
	-- NOTE: we used to skip identical snapshots based on a signature to throttle log noise.
	-- That hid repeated frames in debug runs, so we now always log. To restore throttling,
	-- reintroduce the signature check that returned early when unchanged.
	local signature = snapshotSignature(snapshot, cells)
	lastSignature = signature

	local window = snapshot.window
	local meta = snapshot.meta or {}
	local label = opts.label and (" (" .. tostring(opts.label) .. ")") or ""
	local winSig = windowSignature(window)
	local windowChanged = winSig ~= lastWindowSignature
	lastWindowSignature = winSig

	local hasNewCells = false
	for _, entry in ipairs(cells) do
		local cell = entry.cell or {}
		local id = idForCell(window, entry.col or 1, entry.row or 1)
		local key = cellKey(window, entry, id)
		if cell.composite and not seenCells[key] then
			hasNewCells = true
			break
		end
	end

	local summaryLevel = (windowChanged or hasNewCells) and "info" or "debug"
	logAt(
		summaryLevel,
		"snapshot%s window=[%s,%s] grid=%dx%d cells=%d matches=%d/%d expires=%d/%d",
		label,
		tostring(window.startId),
		tostring(window.endId),
		window.columns or 0,
		window.rows or 0,
		#cells,
		meta.projectableMatchCount or 0,
		meta.matchCount or 0,
		meta.projectableExpireCount or 0,
		meta.expireCount or 0
	)

	for _, entry in ipairs(cells) do
		local cell = entry.cell or {}
		local colZero = (entry.col or 1) - 1
		local rowZero = (entry.row or 1) - 1
		local id = idForCell(window, entry.col or 1, entry.row or 1)
		local key = cellKey(window, entry, id)
		local hasInner = cell.composite and cell.composite:getInner()
		local isNew = hasInner and not seenCells[key]
		if isNew then
			seenCells[key] = true
		end
		local cellLevel = isNew and "info" or "debug"
		local innerColor, innerActive
		if cell.composite then
			local innerRegion = cell.composite:getInner()
			if innerRegion then
				innerColor, innerActive = innerRegion:getColor()
			end
		end
		if innerColor then
			local metaInner = cell.innerMeta or {}
			logAt(
				cellLevel,
				"  cell %d,%d id=%s inner schema=%s recordId=%s layers=%d color=%s",
				colZero,
				rowZero,
				tostring(id),
				tostring(metaInner.schema),
				tostring(metaInner.recordId),
				innerActive or 0,
				formatColor(innerColor)
			)
		else
			logAt(cellLevel, "  cell %d,%d id=%s (no inner fill)", colZero, rowZero, tostring(id))
			seenCells[key] = nil
		end
		local layers = {}
		for layer in pairs(cell.borderMeta or {}) do
			layers[#layers + 1] = layer
		end
		table.sort(layers)
		for _, layer in ipairs(layers) do
			local region = cell.composite and cell.composite:getBorder(layer)
			local borderColor, active = region and region:getColor()
			local metaBorder = cell.borderMeta[layer] or {}
			logAt(
				cellLevel,
				"    border layer=%d kind=%s schema=%s nativeId=%s layers=%d color=%s reason=%s",
				layer,
				tostring(metaBorder.kind),
				tostring(metaBorder.nativeSchema),
				tostring(metaBorder.nativeId),
				active or 0,
				formatColor(borderColor or NEUTRAL_BORDER_COLOR),
				tostring(metaBorder.reason)
			)
		end
	end

	local sourceSummary = {}
	for schema, count in pairs(meta.sourceCounts or {}) do
		sourceSummary[#sourceSummary + 1] = string.format(
			"%s=%d (%d projectable/%d non-projectable)",
			schema,
			count,
			(meta.projectableSourceCounts or {})[schema] or 0,
			(meta.nonProjectableSourceCounts or {})[schema] or 0
		)
	end
	table.sort(sourceSummary)
	if #sourceSummary > 0 then
		logAt(summaryLevel, "  sources: %s", table.concat(sourceSummary, "; "))
	end
	local nonProjMatch = (meta.matchCount or 0) - (meta.projectableMatchCount or 0)
	local nonProjExpire = (meta.expireCount or 0) - (meta.projectableExpireCount or 0)
	if nonProjMatch > 0 or nonProjExpire > 0 then
		logAt(summaryLevel, "  non-projectable totals: match=%d expire=%d", nonProjMatch, nonProjExpire)
	end
end

return VizLogFormatter
