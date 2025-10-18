-- Headless renderer that converts runtime state into a drawable snapshot (no pixels).
-- Useful for tests and trace replay to validate layout/layering logic.

local DEFAULT_INNER_COLOR = { 0.2, 0.2, 0.2, 1 }
local DEFAULT_MATCH_COLOR = { 0.2, 0.85, 0.2, 1 }
local DEFAULT_EXPIRE_COLOR = { 0.9, 0.25, 0.25, 1 }

local Renderer = {}

local function mapIdToCell(window, id)
	if not id then
		return nil, nil
	end
	local idx = id - window.startId + 1
	if idx < 1 then
		return nil, nil
	end
	local total = window.columns * window.rows
	if idx > total then
		return nil, nil
	end
	local col = ((idx - 1) % window.columns) + 1
	local row = math.floor((idx - 1) / window.columns) + 1
	return col, row
end

local function ensureCell(snapshot, col, row)
	snapshot.cells[col] = snapshot.cells[col] or {}
	snapshot.cells[col][row] = snapshot.cells[col][row] or { borders = {} }
	return snapshot.cells[col][row]
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
	if event.id ~= nil then
		return event.id
	end
	if event.left and event.left.id ~= nil then
		return event.left.id
	end
	if event.right and event.right.id ~= nil then
		return event.right.id
	end
	return event.key
end

function Renderer.render(runtime, palette)
	assert(runtime and runtime.window, "runtime with window() required")
	local window = runtime:window()
	local snapshot = {
		window = window,
		cells = {},
	}

	for _, evt in ipairs(runtime.events.source or {}) do
		local col, row = mapIdToCell(window, evt.id)
		if col and row then
			local cell = ensureCell(snapshot, col, row)
			if not cell.inner then
				cell.inner = {
					schema = evt.schema,
					id = evt.id,
					color = colorForSchema(palette, evt.schema),
				}
			end
		end
	end

	for _, evt in ipairs(runtime.events.match or {}) do
		local id = extractId(evt)
		local col, row = mapIdToCell(window, id)
		if col and row then
			local cell = ensureCell(snapshot, col, row)
			cell.borders[evt.layer] = {
				kind = "match",
				id = id,
				color = colorForKind(palette, "match"),
			}
		end
	end

	for _, evt in ipairs(runtime.events.expire or {}) do
		local id = extractId(evt)
		local col, row = mapIdToCell(window, id)
		if col and row then
			local cell = ensureCell(snapshot, col, row)
			cell.borders[evt.layer] = {
				kind = "expire",
				id = id,
				reason = evt.reason,
				color = colorForKind(palette, "expire"),
			}
		end
	end

	return snapshot
end

return Renderer
