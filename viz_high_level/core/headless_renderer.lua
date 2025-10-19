-- Headless renderer that converts runtime state into a drawable snapshot (no pixels).
-- Useful for tests and trace replay to validate layout/layering logic.

local DEFAULT_INNER_COLOR = { 0.2, 0.2, 0.2, 1 }
local DEFAULT_MATCH_COLOR = { 0.2, 0.85, 0.2, 1 }
local DEFAULT_EXPIRE_COLOR = { 0.9, 0.25, 0.25, 1 }

local Renderer = {}
local DEFAULT_NEW_EVENT_WEIGHT = 1
local DEFAULT_MAX_WEIGHT = DEFAULT_NEW_EVENT_WEIGHT -- first hit starts fully saturated
local BACKGROUND_COLOR = { 0.08, 0.08, 0.08, 1 }

local function bumpCount(map, key)
	if not key then
		return
	end
	map[key] = (map[key] or 0) + 1
end

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

local function cloneColor(color)
	if not color then
		return { 1, 1, 1, 1 }
	end
	return { color[1], color[2], color[3], color[4] or 1 }
end

local function decayWeight(weight, deltaSeconds, halfLife)
	if not weight or weight <= 0 then
		return 0
	end
	if not deltaSeconds or deltaSeconds <= 0 then
		return weight
	end
	if not halfLife or halfLife <= 0 then
		return weight
	end
	local lambda = math.log(2) / halfLife
	return weight * math.exp(-lambda * deltaSeconds)
end

local function blendColor(existingColor, existingWeight, newColor, newWeight)
	if not existingColor or existingWeight <= 0 then
		return cloneColor(newColor), math.min(newWeight, DEFAULT_MAX_WEIGHT)
	end
	local totalWeight = existingWeight + newWeight
	if totalWeight <= 0 then
		return cloneColor(newColor), newWeight
	end
	local existingFactor = existingWeight / totalWeight
	local newFactor = newWeight / totalWeight
	return {
		existingColor[1] * existingFactor + newColor[1] * newFactor,
		existingColor[2] * existingFactor + newColor[2] * newFactor,
		existingColor[3] * existingFactor + newColor[3] * newFactor,
		1,
	}, math.min(totalWeight, DEFAULT_MAX_WEIGHT)
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
	local halfLife = runtime.mixDecayHalfLife or runtime.adjustInterval or DEFAULT_ADJUST_INTERVAL
	local currentTime = now or runtime.lastIngestTime or 0
	local snapshot = {
		window = window,
		cells = {},
		meta = {
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

	for _, evt in ipairs(runtime.events.source or {}) do
		local id = evt.projectionKey or evt.id
		local col, row = mapIdToCell(window, id)
		if col and row and evt.projectable then
			local cell = ensureCell(snapshot, col, row)
			if not cell.inner then
				cell.inner = {
					schema = evt.schema,
					id = evt.id,
					color = colorForSchema(palette, evt.schema),
					sourceTime = evt.sourceTime,
					mixWeight = DEFAULT_NEW_EVENT_WEIGHT,
					lastUpdateTime = evt.ingestTime or 0,
				}
			else
			local weight = decayWeight(cell.inner.mixWeight or 0, (evt.ingestTime or 0) - (cell.inner.lastUpdateTime or evt.ingestTime or 0), halfLife)
				local mixedColor, newWeight = blendColor(
					cell.inner.color,
					weight,
					colorForSchema(palette, evt.schema),
					DEFAULT_NEW_EVENT_WEIGHT
				)
				cell.inner.color = mixedColor
				cell.inner.mixWeight = newWeight
				cell.inner.lastUpdateTime = evt.ingestTime or cell.inner.lastUpdateTime
				cell.inner.schema = evt.schema
				cell.inner.id = evt.id
				cell.inner.sourceTime = evt.sourceTime
			end
			bumpCount(snapshot.meta.sourceCounts, evt.schema)
			bumpCount(snapshot.meta.projectableSourceCounts, evt.schema)
		else
			bumpCount(snapshot.meta.sourceCounts, evt.schema)
			bumpCount(snapshot.meta.nonProjectableSourceCounts, evt.schema)
		end
	end

	for _, evt in ipairs(runtime.events.match or {}) do
		local id = evt.projectionKey or extractId(evt)
		local col, row = mapIdToCell(window, id)
		if col and row and evt.projectable then
			local cell = ensureCell(snapshot, col, row)
			cell.borders[evt.layer] = cell.borders[evt.layer] or {}
			local border = cell.borders[evt.layer]
			border.kind = evt.kind or "match"
			border.id = id
			border.nativeId = (evt.right and evt.right.id) or (evt.left and evt.left.id) or evt.id
			border.nativeSchema = (evt.right and evt.right.schema) or (evt.left and evt.left.schema) or evt.schema
			border.projectionDomain = snapshot.meta.header.projection and snapshot.meta.header.projection.domain
			local color = colorForKind(palette, "match")
			if border.color then
				local weight = decayWeight(border.mixWeight or 0, (evt.ingestTime or 0) - (border.lastUpdateTime or evt.ingestTime or 0), halfLife)
				local mixedColor, newWeight = blendColor(border.color, weight, color, DEFAULT_NEW_EVENT_WEIGHT)
				border.color = mixedColor
				border.mixWeight = newWeight
			else
				border.color = cloneColor(color)
				border.mixWeight = DEFAULT_NEW_EVENT_WEIGHT
			end
			border.lastUpdateTime = evt.ingestTime or border.lastUpdateTime
			snapshot.meta.matchCount = snapshot.meta.matchCount + 1
			snapshot.meta.projectableMatchCount = snapshot.meta.projectableMatchCount + 1
		else
			snapshot.meta.matchCount = snapshot.meta.matchCount + 1
		end
	end

	for _, evt in ipairs(runtime.events.expire or {}) do
		local id = evt.projectionKey or extractId(evt)
		local col, row = mapIdToCell(window, id)
		if col and row and evt.projectable then
			local cell = ensureCell(snapshot, col, row)
			cell.borders[evt.layer] = cell.borders[evt.layer] or {}
			local border = cell.borders[evt.layer]
			border.kind = "expire"
			border.id = id
			border.nativeId = evt.id
			border.nativeSchema = evt.schema
			border.projectionDomain = snapshot.meta.header.projection and snapshot.meta.header.projection.domain
			border.reason = evt.reason
			local color = colorForKind(palette, "expire")
			if border.color then
				local weight = decayWeight(border.mixWeight or 0, (evt.ingestTime or 0) - (border.lastUpdateTime or evt.ingestTime or 0), halfLife)
				local mixedColor, newWeight = blendColor(border.color, weight, color, DEFAULT_NEW_EVENT_WEIGHT)
				border.color = mixedColor
				border.mixWeight = newWeight
			else
				border.color = cloneColor(color)
				border.mixWeight = DEFAULT_NEW_EVENT_WEIGHT
			end
			border.lastUpdateTime = evt.ingestTime or border.lastUpdateTime
			snapshot.meta.expireCount = snapshot.meta.expireCount + 1
			snapshot.meta.projectableExpireCount = snapshot.meta.projectableExpireCount + 1
		else
			snapshot.meta.expireCount = snapshot.meta.expireCount + 1
		end
	end

	for _, column in pairs(snapshot.cells) do
		for _, cell in pairs(column) do
			if cell.inner then
				local elapsed = currentTime - (cell.inner.lastUpdateTime or currentTime)
				cell.inner.mixWeight = decayWeight(cell.inner.mixWeight or 0, elapsed, halfLife)
				cell.inner.intensity = math.min((cell.inner.mixWeight or 0) / DEFAULT_MAX_WEIGHT, 1)
			end
			for _, border in pairs(cell.borders or {}) do
				local elapsed = currentTime - (border.lastUpdateTime or currentTime)
				border.mixWeight = decayWeight(border.mixWeight or 0, elapsed, halfLife)
				border.opacity = math.min((border.mixWeight or 0) / DEFAULT_MAX_WEIGHT, 1)
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
