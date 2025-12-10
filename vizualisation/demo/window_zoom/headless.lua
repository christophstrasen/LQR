-- Headless helper: drive the window_zoom timeline to show auto-zoom up to 100x100,
-- then the slide-forward behavior once the burst has faded.
package.path = "./?.lua;./?/init.lua;" .. package.path
require('LQR.bootstrap')

local Log = require("LQR.util.log").withTag("demo")
local Runtime = require("vizualisation.core.runtime")
local Renderer = require("vizualisation.core.headless_renderer")
local DebugViz = require("vizualisation.vizLogFormatter")
local QueryVizAdapter = require("vizualisation.core.query_adapter")
local WindowZoomScenario = require("vizualisation.demo.window_zoom")

local demo = WindowZoomScenario.build()
local adapter = QueryVizAdapter.attach(demo.builder, { logEvents = false })
local defaults = WindowZoomScenario.loveDefaults or {}

local clock = {
	value = 0,
	set = function(self, value)
		self.value = value or 0
	end,
	now = function(self)
		return self.value or 0
	end,
}

local runtime = Runtime.new({
	maxLayers = 1,
	adjustInterval = defaults.adjustInterval or 0.5,
	header = adapter.header,
	visualsTTL = defaults.visualsTTL or 2.5,
})

adapter.normalized:subscribe(function(evt)
	runtime:ingest(evt, clock:now())
end)

adapter.query:subscribe(function() end)

local driver = WindowZoomScenario.start(demo.subjects, {
	ticksPerSecond = defaults.ticksPerSecond or 1.2,
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

for _, snapInfo in ipairs(WindowZoomScenario.snapshots or {}) do
	local tag = string.format("window_zoom_%s", snapInfo.label or tostring(snapInfo.tick))
	capture(tag, snapInfo.tick)
end

if driver and driver.runAll then
	driver:runAll()
end

clock:set(clock:now() + 0.5)
local snap = Renderer.render(runtime, adapter.palette, clock:now())
DebugViz.snapshot(snap, { label = "window_zoom_final", logSnapshots = true })

local window = runtime:window()
Log.info(
	"win[%s,%s] %dx%d start=%s zoom=%s margin=%s (%.0f%%) "
		.. "src=%d join=%d exp=%d proj(j=%d,e=%d)",
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
