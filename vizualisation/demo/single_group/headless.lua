package.path = "./?.lua;./?/init.lua;" .. package.path
require("bootstrap")

local Runtime = require("vizualisation.core.runtime")
local Renderer = require("vizualisation.core.headless_renderer")
local DebugViz = require("vizualisation.vizLogFormatter")
local Log = require("log")
local QueryVizAdapter = require("vizualisation.core.query_adapter")
local SingleGroupDemo = require("vizualisation.demo.single_group")

-- Headless demo can be noisy at INFO; drop join-tag logs by default.
local previousEmitter
local joinLogs = os.getenv("HEADLESS_JOIN_LOGS")
if joinLogs ~= "1" then
	local prev
	prev = Log.setEmitter(function(level, message, tag)
		if tag == "join" then
			return
		end
		if prev then
			prev(level, message, tag)
		end
	end)
	previousEmitter = prev
end

local demo = SingleGroupDemo.build()
local adapter = QueryVizAdapter.attach(demo.builder, { logEvents = false })
local defaults = SingleGroupDemo.loveDefaults or {}

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
	visualsTTLFactors = defaults.visualsTTLFactors,
	visualsTTLLayerFactors = defaults.visualsTTLLayerFactors,
	maxColumns = defaults.maxColumns,
	maxRows = defaults.maxRows,
	startId = defaults.startId,
	lockWindow = defaults.lockWindow,
})

adapter.normalized:subscribe(function(evt)
	runtime:ingest(evt, clock:now())
end)

adapter.query:subscribe(function() end)

-- Console demo: log grouped aggregates after HAVING (builder already includes grouping/having).
if demo.builder then
	demo.builder:subscribe(function(row)
		local sum = row.events and row.events._sum
		local avg = row.events and row.events._avg
		local latest = row.events and row.events.value
		io.stdout:write(string.format(
			"[group][agg][after HAVING][type=%s] count=%s latest=%s sum=%s avg=%s schema=%s\n",
			tostring(row.key),
			tostring(row._count),
			tostring(latest),
			tostring(sum and sum.value),
			tostring(avg and avg.value),
			tostring(row.RxMeta and row.RxMeta.schema)
		))
		io.stdout:flush()
	end)
end

local driver = SingleGroupDemo.start(demo.subjects, {
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

for _, snapInfo in ipairs(SingleGroupDemo.snapshots or {}) do
	local tag = string.format("single_group_%s", snapInfo.label or tostring(snapInfo.tick))
	capture(tag, snapInfo.tick)
end

if driver and driver.runAll then
	driver:runAll()
end

clock:set(clock:now() + 0.25)
local snap = Renderer.render(runtime, adapter.palette, clock:now())
DebugViz.snapshot(snap, { label = "single_group_final", logSnapshots = true })

if previousEmitter then
	Log.setEmitter(previousEmitter)
end
