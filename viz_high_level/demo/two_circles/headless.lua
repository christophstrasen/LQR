package.path = "./?.lua;./?/init.lua;" .. package.path
require("bootstrap")

local Runtime = require("viz_high_level.core.runtime")
local Renderer = require("viz_high_level.core.headless_renderer")
local DebugViz = require("viz_high_level.vizLogFormatter")
local QueryVizAdapter = require("viz_high_level.core.query_adapter")
local TwoCirclesDemo = require("viz_high_level.demo.two_circles")

local demo = TwoCirclesDemo.build()
local adapter = QueryVizAdapter.attach(demo.builder)
local defaults = TwoCirclesDemo.loveDefaults or {}

local clock = {
	value = 0,
	set = function(self, value)
		self.value = value or 0
	end,
	now = function(self)
		return self.value or 0
	end,
}

local visualsTTL = (defaults.visualsTTL or 2.5) * (defaults.visualsTTLFactor or 1)

local runtime = Runtime.new({
	maxLayers = 1,
	adjustInterval = defaults.adjustInterval or 0.5,
	header = adapter.header,
	visualsTTL = visualsTTL,
	visualsTTLFactor = 1,
	maxColumns = defaults.maxColumns,
	maxRows = defaults.maxRows,
	startId = defaults.startId,
	lockWindow = defaults.lockWindow,
})

adapter.normalized:subscribe(function(evt)
	runtime:ingest(evt, clock:now())
end)

adapter.query:subscribe(function() end)

local driver = TwoCirclesDemo.start(demo.subjects, {
	playbackSpeed = defaults.playbackSpeed or defaults.ticksPerSecond or 2,
	clock = clock,
})

local function capture(label, tick)
	if driver and driver.runUntil then
		driver:runUntil(tick)
	end
	clock:set(tick)
	local snapshot = Renderer.render(runtime, adapter.palette, clock:now())
	DebugViz.snapshot(snapshot, { label = label })
	return snapshot
end

for _, snapInfo in ipairs(TwoCirclesDemo.snapshots or {}) do
	local tag = string.format("two_circles_%s", snapInfo.label or tostring(snapInfo.tick))
	capture(tag, snapInfo.tick)
end

if driver and driver.runAll then
	driver:runAll()
end

clock:set(clock:now() + 0.25)
local snap = Renderer.render(runtime, adapter.palette, clock:now())
DebugViz.snapshot(snap, { label = "two_circles_final" })
