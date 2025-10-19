-- Debug logging helpers for high-level visualization snapshots.
-- Emits detailed cell/border summaries when debug logging is enabled.
local DebugViz = {}
local Log = require("log")
local VizLog = Log.withTag("viz")
local lastSignature
local seenCells = {}
local lastWindowSignature

local function logAt(level, fmt, ...)
	if level == "info" then
		VizLog:info(fmt, ...)
	else
		VizLog:debug(fmt, ...)
	end
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
		if cell.inner then
			parts[#parts + 1] = table.concat({
				"I",
				entry.col,
				entry.row,
				tostring(cell.inner.schema),
				tostring(cell.inner.id),
				string.format("%.2f", cell.inner.mixWeight or 0),
			}, ":")
		end
		local layers = {}
		for layer in pairs(cell.borders or {}) do
			layers[#layers + 1] = layer
		end
		table.sort(layers)
		for _, layer in ipairs(layers) do
			local border = cell.borders[layer]
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

---Logs detailed cell/border information for a snapshot when DEBUG is enabled.
---@param snapshot table
---@param opts table|nil
function DebugViz.snapshot(snapshot, opts)
	if not (Log.isEnabled("debug") or Log.isEnabled("info")) then
		return
	end
	if not snapshot or not snapshot.window then
		return
	end
	opts = opts or {}
	local cells = collectCells(snapshot)
	local signature = snapshotSignature(snapshot, cells)
	if not opts.force and signature == lastSignature then
		return
	end
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
		if cell.inner and not seenCells[key] then
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
		local isNew = cell.inner and not seenCells[key]
		if isNew then
			seenCells[key] = true
		end
		local cellLevel = isNew and "info" or "debug"
		if cell.inner then
			logAt(
				cellLevel,
				"  cell %d,%d id=%s inner schema=%s recordId=%s mix=%.2f intensity=%.2f color=%s",
				colZero,
				rowZero,
				tostring(id),
				tostring(cell.inner.schema),
				tostring(cell.inner.id),
				cell.inner.mixWeight or 0,
				cell.inner.intensity or 0,
				formatColor(cell.inner.color)
			)
		else
			logAt(cellLevel, "  cell %d,%d id=%s (no inner fill)", colZero, rowZero, tostring(id))
			seenCells[key] = nil
		end
		local layers = {}
		for layer in pairs(cell.borders or {}) do
			layers[#layers + 1] = layer
		end
		table.sort(layers)
		for _, layer in ipairs(layers) do
			local border = cell.borders[layer]
			if border then
				logAt(
					cellLevel,
					"    border layer=%d kind=%s schema=%s nativeId=%s opacity=%.2f color=%s reason=%s",
					layer,
					tostring(border.kind),
					tostring(border.nativeSchema),
					tostring(border.nativeId),
					border.opacity or 0,
					formatColor(border.color),
					tostring(border.reason)
				)
			end
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

return DebugViz
