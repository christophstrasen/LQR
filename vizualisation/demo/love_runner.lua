local Log = require("util.log").withTag("demo")
local QueryVizAdapter = require("vizualisation.core.query_adapter")
local Runtime = require("vizualisation.core.runtime")
local Renderer = require("vizualisation.core.headless_renderer")
local DebugViz = require("vizualisation.vizLogFormatter")
local Draw = require("vizualisation.core.draw")
local Color = require("util.color")

local LoveRunner = {}

local DEFAULT_BACKGROUND = { 0.08, 0.08, 0.08, 1 }
local HOVER_HISTORY_LIMIT = 6 -- match runtime default for consistency

local function fieldLabel(join)
	local keyDesc = join.displayKey or "id"
	local layer = join.layer and string.format(" [layer %d]", join.layer) or ""
	return string.format("%s join %s on %s%s", join.type or "join", join.source or "right", keyDesc, layer)
end

local function drawHeader(snapshot, lg, backgroundColor)
	local headerY = 10
	local headerData = snapshot.meta.header or {}
	local window = headerData.window or snapshot.window
	if window then
		local rangeText = string.format(
			"Showing records on id range %s-%s (grid %dx%d)",
			tostring(window.startId),
			tostring(window.endId),
			window.columns or 0,
			window.rows or 0
		)
		lg.printf(rangeText, 12, headerY, love.graphics.getWidth() - 24, "left")
		headerY = headerY + 22
		if window.gc then
			local gcText
			if window.gc.gcIntervalSeconds and window.gc.gcIntervalSeconds > 0 then
				gcText = string.format(
					"GC: interval=%.2fs%s",
					window.gc.gcIntervalSeconds,
					window.gc.gcOnInsert and " + per insert" or ""
				)
			elseif window.gc.gcOnInsert == false then
				gcText = "GC: onComplete only"
			else
				gcText = "GC: per insert"
			end
			lg.printf(gcText, 12, headerY, love.graphics.getWidth() - 24, "left")
			headerY = headerY + 22
		end
	end
	if headerData.from and #headerData.from > 0 then
		local fromText = string.format("from %s", table.concat(headerData.from, ", "))
		lg.printf(fromText, 12, headerY, love.graphics.getWidth() - 24, "left")
		headerY = headerY + 22
	end

	local joins = headerData.joins or {}
	for _, join in ipairs(joins) do
		lg.printf(fieldLabel(join), 12, headerY, love.graphics.getWidth() - 24, "left")
		headerY = headerY + 18
		local joinWindow = join.joinWindow
		if joinWindow then
			local wtxt
			if joinWindow.mode == "count" then
				wtxt = string.format("Count join window=%s", tostring(joinWindow.count))
			elseif joinWindow.mode == "time" then
				wtxt = string.format(
					"Time join window field=%s offset=%s",
					tostring(joinWindow.field),
					tostring(joinWindow.time)
				)
			end
			if wtxt then
				lg.printf(wtxt, 12, headerY, love.graphics.getWidth() - 24, "left")
				headerY = headerY + 18
			end
		end
	end

	local legend = snapshot.meta.legend or {}
	if #legend > 0 then
		headerY = headerY + 8
		for _, entry in ipairs(legend) do
			local rectSize = 16
			local x = 12
			lg.setColor(entry.color or { 1, 1, 1, 1 })
			lg.rectangle("fill", x, headerY, rectSize, rectSize)
			lg.setColor(1, 1, 1, 1)
			local label = string.format(
				"%s (%d total, %d projectable, %d non-projectable)",
				entry.schema,
				entry.count or 0,
				entry.projectable or 0,
				entry.nonProjectable or 0
			)
			lg.printf(label, x + rectSize + 8, headerY, love.graphics.getWidth() - x - rectSize - 16, "left")
			headerY = headerY + 20
		end
	end

	local outerLegend = snapshot.meta.outerLegend or {}
	if #outerLegend > 0 then
		headerY = headerY + 4
		for _, entry in ipairs(outerLegend) do
			local rectSize = 16
			local x = 12
			lg.setColor(entry.color or { 1, 1, 1, 1 })
			lg.rectangle("fill", x, headerY, rectSize, rectSize)
			local inset = 2
			local bg = backgroundColor or DEFAULT_BACKGROUND
			lg.setColor(bg[1], bg[2], bg[3], bg[4])
			lg.rectangle("fill", x + inset, headerY + inset, rectSize - inset * 2, rectSize - inset * 2)
			lg.setColor(1, 1, 1, 1)
			local total = entry.total or 0
			local projectable = entry.projectable or 0
			if entry.kind == "expire" then
				total = snapshot.meta.expireCount or total
				projectable = snapshot.meta.projectableExpireCount or projectable
			end
			local nonProjectable = math.max(total - projectable, 0)
			local countLabel =
				string.format(" (%d total, %d projectable, %d non-projectable)", total, projectable, nonProjectable)
			local reasonLabel = ""
			if entry.kind == "expire" and entry.reasons and #entry.reasons > 0 then
				local parts = {}
				for _, reason in ipairs(entry.reasons) do
					parts[#parts + 1] = string.format("%s: %d", reason.reason, reason.total)
				end
				reasonLabel = " Expiration reasons: [" .. table.concat(parts, ", ") .. "]"
			end
			local label = (entry.label or entry.kind) .. countLabel .. reasonLabel
			lg.printf(label, x + rectSize + 8, headerY, love.graphics.getWidth() - x - rectSize - 16, "left")
			headerY = headerY + 20
		end
	end

	local nonProjMatch = (snapshot.meta.matchCount or 0) - (snapshot.meta.projectableMatchCount or 0)
	local nonProjExpire = (snapshot.meta.expireCount or 0) - (snapshot.meta.projectableExpireCount or 0)
	if nonProjMatch > 0 or nonProjExpire > 0 then
		lg.printf(
			string.format("Non-projectable: match=%d, expire=%d", nonProjMatch, nonProjExpire),
			12,
			headerY,
			love.graphics.getWidth() - 24,
			"left"
		)
		headerY = headerY + 20
	end

	return headerY
end

local function drawSnapshot(snapshot, background)
	local lg = love.graphics
	lg.clear(background[1], background[2], background[3], background[4])
	lg.setColor(1, 1, 1, 1)
	local headerBase = drawHeader(snapshot, lg, background)
	local metrics = Draw.metrics(snapshot)
	local originX = 12 + (metrics.rowLabelWidth or 0)
	local originY = headerBase + 10 + (metrics.columnLabelHeight or 0)
	lg.push()
	lg.translate(originX, originY)
	Draw.drawSnapshot(snapshot, { showLabels = true })
	lg.pop()
	return {
		originX = originX,
		originY = originY,
		metrics = metrics,
		headerBase = headerBase,
	}
end

local function hoveredCell(snapshot, drawMeta)
	if not snapshot or not drawMeta or not drawMeta.metrics then
		return nil
	end
	local window = snapshot.window or (snapshot.meta and snapshot.meta.header and snapshot.meta.header.window)
	if not window then
		return nil
	end
	local mx, my = love.mouse.getPosition()
	local gridX = mx - drawMeta.originX
	local gridY = my - drawMeta.originY
	if gridX < 0 or gridY < 0 then
		return nil
	end
	local col = math.floor(gridX / drawMeta.metrics.cellSize) + 1
	local row = math.floor(gridY / drawMeta.metrics.cellSize) + 1
	if col < 1 or col > (drawMeta.metrics.columns or 0) or row < 1 or row > (drawMeta.metrics.rows or 0) then
		return nil
	end
	local id = (window.startId or 0) + (col - 1) * (window.rows or 0) + (row - 1)
	return {
		col = col,
		row = row,
		id = id,
	}
end

local function describeHistoryEntry(entry)
	if not entry then
		return ""
	end
	local parts = {}
	parts[#parts + 1] = string.format("t=%.2fs", entry.at or 0)
	parts[#parts + 1] = entry.kind or entry.type or "event"
	if entry.layer then
		parts[#parts + 1] = string.format("layer=%s", tostring(entry.layer))
	end
	if entry.schema then
		parts[#parts + 1] = string.format("schema=%s", tostring(entry.schema))
	end
	if entry.id then
		parts[#parts + 1] = string.format("id=%s", tostring(entry.id))
	end
	if entry.reason then
		parts[#parts + 1] = string.format("reason=%s", tostring(entry.reason))
	end
	if entry.side then
		parts[#parts + 1] = string.format("side=%s", tostring(entry.side))
	end
	return table.concat(parts, " ")
end

local function drawHoverOverlay(snapshot, drawMeta)
	local history = snapshot.meta and snapshot.meta.history or {}
	local hover = hoveredCell(snapshot, drawMeta)
	if not hover or not hover.id then
		return
	end

	local lg = love.graphics
	-- Highlight the hovered cell.
	lg.setColor(1, 1, 1, 0.8)
	lg.setLineWidth(2)
	local boxSize = drawMeta.metrics.cellSize
	local boxX = drawMeta.originX + (hover.col - 1) * boxSize
	local boxY = drawMeta.originY + (hover.row - 1) * boxSize
	lg.rectangle("line", boxX, boxY, boxSize, boxSize)

	-- Build hover panel content as a single flowing text block so Love wraps naturally.
	local entries = history[hover.id]
	local lines = {}
	lines[#lines + 1] = string.format("cell id=%s (col=%d,row=%d)", tostring(hover.id), hover.col, hover.row)
	if not entries or #entries == 0 then
		lines[#lines + 1] = "no recent events"
	else
		for i = #entries, math.max(#entries - HOVER_HISTORY_LIMIT + 1, 1), -1 do
			lines[#lines + 1] = describeHistoryEntry(entries[i])
		end
	end
	local text = table.concat(lines, "\n")

	-- Render panel in top-right (50% wider to reduce wraps).
	local panelWidth = math.floor(380 * 1.5)
	local margin = 12
	local font = love.graphics.getFont()
	local _, wrapped = font:getWrap(text, panelWidth - 16)
	local lineHeight = font:getHeight()
	local panelHeight = (#wrapped * lineHeight) + (margin * 2)
	local panelX = love.graphics.getWidth() - panelWidth - margin
	local panelY = margin

	lg.setColor(0, 0, 0, 0.75)
	lg.rectangle("fill", panelX, panelY, panelWidth, panelHeight)
	lg.setColor(1, 1, 1, 1)
	lg.printf(text, panelX + 8, panelY + margin * 0.5, panelWidth - 16, "left")
end

---@param opts table
function LoveRunner.bootstrap(opts)
	opts = opts or {}
	assert(opts.scenarioModule, "scenarioModule required")
	local scenario = require(opts.scenarioModule)
	local defaults = scenario.loveDefaults or {}
	local visualsTTL = opts.visualsTTL or defaults.visualsTTL or 3
	local visualsTTLFactor = opts.visualsTTLFactor or defaults.visualsTTLFactor or 1
	local effectiveVisualsTTL = visualsTTL * visualsTTLFactor
	local ttlFactors = opts.visualsTTLFactors or defaults.visualsTTLFactors or {}
	local layerFactors = opts.visualsTTLLayerFactors or defaults.visualsTTLLayerFactors or {}
	local function maxLayerFactor()
		local max = 1
		for _, factor in pairs(layerFactors) do
			if type(factor) == "number" and factor > max then
				max = factor
			end
		end
		return max
	end
	local function maxKindFactor()
		local max = 1
		for _, factor in pairs({ ttlFactors.source, ttlFactors.joined, ttlFactors.final, ttlFactors.expire }) do
			if type(factor) == "number" and factor > max then
				max = factor
			end
		end
		return max
	end
	local maxEffectiveTTL = effectiveVisualsTTL * maxKindFactor() * maxLayerFactor()
	local playbackSpeed = opts.playbackSpeed or defaults.playbackSpeed or defaults.ticksPerSecond or 0
	local adjustInterval = opts.adjustInterval or defaults.adjustInterval or 1.5
	local windowWidth = (defaults.windowSize and defaults.windowSize[1]) or 800
	local windowHeight = (defaults.windowSize and defaults.windowSize[2]) or 600
	local background = Color.clone(defaults.backgroundColor, DEFAULT_BACKGROUND)
	local lockWindow = defaults.lockWindow or opts.lockWindow
	local clockMode = opts.clockMode or defaults.clockMode or "love" -- "driver" keeps time in scenario/driver, "love" advances per frame
	local clockRate = opts.clockRate or defaults.clockRate or playbackSpeed or 1
	local fadeBudget = maxEffectiveTTL * 1.1
	local clock = {
		value = 0,
		now = function(self)
			return self.value or 0
		end,
		set = function(self, v)
			self.value = v or 0
		end,
	}

	local state = {
		attachment = nil,
		runtime = nil,
		driver = nil,
		background = background,
		clock = clock,
		fadeStop = nil,
		visualsTTL = effectiveVisualsTTL,
	}

	local scenarioClock = (clockMode == "driver") and clock or nil

	local function startScenario()
		local demo = assert(scenario.build(scenarioClock), "scenario build() must return subjects + builder")
		assert(demo.builder, "scenario build() result missing builder")
		assert(demo.subjects, "scenario build() result missing subjects")
		state.attachment = QueryVizAdapter.attach(demo.builder)
		state.runtime = Runtime.new({
			maxLayers = state.attachment.maxLayers,
			palette = state.attachment.palette,
			adjustInterval = adjustInterval,
			header = state.attachment.header,
			visualsTTL = effectiveVisualsTTL,
			visualsTTLFactor = 1,
			visualsTTLFactors = opts.visualsTTLFactors or defaults.visualsTTLFactors,
			visualsTTLLayerFactors = opts.visualsTTLLayerFactors or defaults.visualsTTLLayerFactors,
			maxColumns = defaults.maxColumns,
			maxRows = defaults.maxRows,
			startId = defaults.startId,
			lockWindow = lockWindow,
		})

		state.attachment.normalized:subscribe(function(event)
			state.runtime:ingest(event, state.clock:now())
		end)

		state.attachment.query:subscribe(function() end)

		state.driver = scenario.start
			and scenario.start(demo.subjects, {
				playbackSpeed = playbackSpeed,
				ticksPerSecond = playbackSpeed,
				clock = scenarioClock,
			})
		if (not state.driver) and scenario.complete then
			scenario.complete(demo.subjects)
		end
	end

	function love.load()
		love.window.setMode(windowWidth, windowHeight, { resizable = true })
		local scenarioName = tostring(opts.scenarioModule or "unknown")
		Log:info("Initializing high-level viz demo (%s)", scenarioName)
		startScenario()
	end

	function love.update(dt)
		local driver = state.driver

		if clockMode == "driver" then
			-- In driver mode the scheduler advances the shared clock until it finishes.
			-- After completion, we continue to advance time for a short fade so visuals expire.
			if driver and driver.isFinished and driver:isFinished() then
				if not state.fadeStop then
					state.fadeStop = state.clock:now() + fadeBudget
				end
				if state.clock:now() < state.fadeStop then
					state.clock:set(state.clock:now() + (dt or 0) * clockRate)
				end
			end
		else
			state.clock:set(state.clock:now() + (dt or 0) * clockRate)
		end

		if driver and driver.update then
			driver:update(dt)
		end
	end

	function love.draw()
		local runtime = state.runtime
		local attachment = state.attachment
		if not runtime then
			return
		end
		local snapshot = Renderer.render(runtime, attachment.palette, state.clock:now())
		DebugViz.snapshot(snapshot, { label = "love-frame" })
		local drawMeta = drawSnapshot(snapshot, state.background)
		drawHoverOverlay(snapshot, drawMeta)
	end

	function love.quit()
		-- nothing to clean up; Love handles exit.
	end
end

return LoveRunner
