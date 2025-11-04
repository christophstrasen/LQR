local Log = require("log").withTag("demo")
local QueryVizAdapter = require("viz_high_level.core.query_adapter")
local Runtime = require("viz_high_level.core.runtime")
local Renderer = require("viz_high_level.core.headless_renderer")
local DebugViz = require("viz_high_level.vizLogFormatter")
local Draw = require("viz_high_level.core.draw")

local LoveRunner = {}

local DEFAULT_BACKGROUND = { 0.08, 0.08, 0.08, 1 }

local function cloneColor(color)
	if not color then
		return { 0, 0, 0, 1 }
	end
	return { color[1] or 0, color[2] or 0, color[3] or 0, color[4] or 1 }
end

local function fieldLabel(join)
	local keyDesc = join.displayKey or "id"
	return string.format("%s join %s on %s", join.type or "join", join.source or "right", keyDesc)
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
		if join.window then
			local wtxt
			if join.window.mode == "count" then
				wtxt = string.format("Count window=%s", tostring(join.window.count))
			elseif join.window.mode == "time" then
				wtxt = string.format(
					"Time window field=%s offset=%s",
					tostring(join.window.field),
					tostring(join.window.time)
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
			local countLabel = ""
			if entry.kind == "match" then
				countLabel = string.format(
					" (%d projectable/%d total)",
					snapshot.meta.projectableMatchCount or 0,
					snapshot.meta.matchCount or 0
				)
			elseif entry.kind == "expire" then
				countLabel = string.format(
					" (%d projectable/%d total)",
					snapshot.meta.projectableExpireCount or 0,
					snapshot.meta.expireCount or 0
				)
			end
			local label = (entry.label or entry.kind) .. countLabel
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
	lg.translate(originX, originY)
	Draw.drawSnapshot(snapshot, { showLabels = true })
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
		for _, factor in pairs({ ttlFactors.source, ttlFactors.match, ttlFactors.expire }) do
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
	local background = cloneColor(defaults.backgroundColor or DEFAULT_BACKGROUND)
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

		state.driver = scenario.start and scenario.start(demo.subjects, {
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
		drawSnapshot(snapshot, state.background)
	end

	function love.quit()
		-- nothing to clean up; Love handles exit.
	end
end

return LoveRunner
