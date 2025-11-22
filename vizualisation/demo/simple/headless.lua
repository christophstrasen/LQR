-- Minimal headless trace for the snapshot demo so we can keep verifying the static setup.
package.path = "./?.lua;./?/init.lua;" .. package.path
require("bootstrap")

local Log = require("log").withTag("demo")
local Runtime = require("vizualisation.core.runtime")
local Renderer = require("vizualisation.core.headless_renderer")
local DebugViz = require("vizualisation.vizLogFormatter")
local QueryVizAdapter = require("vizualisation.core.query_adapter")
local SimpleDemo = require("vizualisation.demo.simple")

local demo = SimpleDemo.build()
local adapter = QueryVizAdapter.attach(demo.builder, { logEvents = false })
local runtime = Runtime.new({
	maxLayers = 2,
	adjustInterval = 1,
	header = adapter.header,
	visualsTTL = 10,
})

adapter.normalized:subscribe(function(evt)
	runtime:ingest(evt, os.clock())
end)

adapter.query:subscribe(function() end)

SimpleDemo.start(demo.subjects)

local snapshot = Renderer.render(runtime, adapter.palette, os.clock())
DebugViz.snapshot(snapshot, { label = "simple_final", logSnapshots = true })

local window = runtime:window()
Log.info(
	"[simple-demo] window=[%s,%s] grid=%dx%d zoom=%s sources=%d joins=%d expires=%d",
	tostring(window.startId),
	tostring(window.endId),
	window.columns or 0,
	window.rows or 0,
	window.zoomState or "auto",
	#runtime.events.source,
	#runtime.events.match,
	#runtime.events.expire
)
