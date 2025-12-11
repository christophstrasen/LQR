package.path = "./?.lua;" .. package.path
require('LQR/bootstrap')

local Runtime = require("vizualisation/core/runtime")
local Renderer = require("vizualisation/core/headless_renderer")
local DebugViz = require("vizualisation/vizLogFormatter")
local QueryVizAdapter = require("vizualisation/core/query_adapter")
local TwoZonesDemo = require("vizualisation/demo/two_zones")

local demo = TwoZonesDemo.build()
local adapter = QueryVizAdapter.attach(demo.builder, { logEvents = false })
local defaults = TwoZonesDemo.loveDefaults or {}

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

local driver = TwoZonesDemo.start(demo.subjects, {
	playbackSpeed = defaults.playbackSpeed or defaults.ticksPerSecond or 2,
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

for _, snapInfo in ipairs(TwoZonesDemo.snapshots or {}) do
	local tag = string.format("two_zones_%s", snapInfo.label or tostring(snapInfo.tick))
	capture(tag, snapInfo.tick)
end

if driver and driver.runAll then
	driver:runAll()
end

clock:set(clock:now() + 0.25)
local snap = Renderer.render(runtime, adapter.palette, clock:now())
DebugViz.snapshot(snap, { label = "two_zones_final", logSnapshots = true })
