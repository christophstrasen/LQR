-- Headless helper: ingest the lively timeline demo, capture deterministic snapshots,
-- and log the resulting grid window for quick sanity checks.
package.path = "./?.lua;./?/init.lua;" .. package.path
require('LQR.bootstrap')

local Log = require("util.log").withTag("demo")
local Runtime = require("LQR.vizualisation.core.runtime")
local Renderer = require("LQR.vizualisation.core.headless_renderer")
local DebugViz = require("LQR.vizualisation.vizLogFormatter")
local QueryVizAdapter = require("LQR.vizualisation.core.query_adapter")
local TimelineScenario = require("LQR.vizualisation.demo.timeline")

local demo = TimelineScenario.build()
local adapter = QueryVizAdapter.attach(demo.builder, { logEvents = false })
local clock = {
	value = 0,
	set = function(self, value)
		self.value = value or 0
	end,
	now = function(self)
		return self.value or 0
	end,
}

local VISUALS_TTL = 3
local runtime = Runtime.new({
	maxLayers = 2,
	adjustInterval = 1,
	header = adapter.header,
	visualsTTL = VISUALS_TTL,
})

adapter.normalized:subscribe(function(evt)
	runtime:ingest(evt, clock:now())
end)

adapter.query:subscribe(function() end)

local driver = TimelineScenario.start(demo.subjects, {
	ticksPerSecond = 3,
	clock = clock,
})

local function capture(label, tick)
	if driver and driver.runUntil then
		driver:runUntil(tick)
	end
	clock:set(tick)
	local snapshot = Renderer.render(runtime, adapter.palette, clock:now())
	DebugViz.snapshot(snapshot, { label = label, logSnapshots = true })
	return snapshot
end

for _, snapInfo in ipairs(TimelineScenario.snapshots or {}) do
	local tag = string.format("timeline_%s", snapInfo.label or tostring(snapInfo.tick))
	capture(tag, snapInfo.tick)
end

if driver and driver.runAll then
	driver:runAll()
end

clock:set(clock:now() + 0.5)
local snap = Renderer.render(runtime, adapter.palette, clock:now())
DebugViz.snapshot(snap, { label = "timeline_final", logSnapshots = true })

local window = runtime:window()
Log.info(
	"window=[%s,%s] grid=%dx%d offset=%s mode=%s margin=%s (%.0f%% cols) sources=%d joins=%d expires=%d projectable(joins=%d,expire=%d)",
	tostring(window.startId),
	tostring(window.endId),
	window.columns or 0,
	window.rows or 0,
	tostring(window.startId),
	window.zoomState or (adapter.header and adapter.header.zoomState) or "auto",
	window.margin or 0,
	((window.marginPercent or 0) * 100),
	#runtime.events.source,
	#runtime.events.match,
	#runtime.events.expire,
	snap.meta.projectableMatchCount or 0,
	snap.meta.projectableExpireCount or 0
)
