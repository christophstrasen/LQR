-- Headless helper: ingest a normalized event trace and print window snapshots.
package.path = "./?.lua;./?/init.lua;" .. package.path

local Log = require("log")
local Runtime = require("viz_high_level.core.runtime")
local Renderer = require("viz_high_level.core.headless_renderer")
local DebugViz = require("viz_high_level.debug")
local QueryVizAdapter = require("viz_high_level.core.query_adapter")
local DemoData = require("viz_high_level.demo.demo_data")

local demo = DemoData.build()
local adapter = QueryVizAdapter.attach(demo.builder)

local MIX_DECAY_HALF_LIFE = 100
local runtime = Runtime.new({
	maxLayers = 5,
	adjustInterval = 1,
	header = adapter.header,
	mixDecayHalfLife = MIX_DECAY_HALF_LIFE,
})

adapter.normalized:subscribe(function(evt)
	runtime:ingest(evt, love and love.timer and love.timer.getTime() or os.clock())
end)

adapter.query:subscribe(function() end)

DemoData.emitBaseline(demo.subjects)
DemoData.complete(demo.subjects)

local now = love and love.timer and love.timer.getTime() or os.clock()
local snap = Renderer.render(runtime, adapter.palette, now)
DebugViz.snapshot(snap, { label = "headless_trace" })

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
