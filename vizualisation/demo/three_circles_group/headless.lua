package.path = "./?.lua;" .. package.path
require('LQR/bootstrap')

local Runtime = require("vizualisation/core/runtime")
local Renderer = require("vizualisation/core/headless_renderer")
local DebugViz = require("vizualisation/vizLogFormatter")
local Log = require("LQR/util/log")
local QueryVizAdapter = require("vizualisation/core/query_adapter")
local ThreeCirclesDemo = require("vizualisation/demo/three_circles_group")

-- Headless demo can be noisy at INFO; drop join-tag logs by default.
-- Opt out with HEADLESS_JOIN_LOGS=1.
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

local demo = ThreeCirclesDemo.build()
local adapter = QueryVizAdapter.attach(demo.builder, { logEvents = false })
local defaults = ThreeCirclesDemo.loveDefaults or {}

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
	maxLayers = 2,
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

-- Console demo: log grouped aggregates and enriched rows with group context.
if demo.groupedAggregate then
	demo.groupedAggregate:subscribe(function(row)
		local sum = row.customers and row.customers.orders and row.customers.orders._sum
		local avg = row.customers and row.customers.orders and row.customers.orders._avg
		Log:info(
			"[group][agg][cust=%s] count=%s sum=%s avg=%s schema=%s",
			tostring(row.RxMeta and row.RxMeta.groupKey),
			tostring(row._count),
			tostring(sum and sum.total),
			tostring(avg and avg.total),
			tostring(row.RxMeta and row.RxMeta.schema)
		)
	end)
end

if demo.groupedEnriched then
	demo.groupedEnriched:subscribe(function(row)
		local sum = row.customers and row.customers.orders and row.customers.orders._sum
		local avg = row.customers and row.customers.orders and row.customers.orders._avg
		Log:info(
			"[group][enr][cust=%s] count=%s latestOrderTotal=%s sum=%s avg=%s",
			tostring(row.RxMeta and row.RxMeta.groupKey),
			tostring(row._count),
			tostring(row.orders and row.orders.total),
			tostring(sum and sum.total),
			tostring(avg and avg.total)
		)
	end)
end

local driver = ThreeCirclesDemo.start(demo.subjects, {
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

for _, snapInfo in ipairs(ThreeCirclesDemo.snapshots or {}) do
	local tag = string.format("three_circles_%s", snapInfo.label or tostring(snapInfo.tick))
	capture(tag, snapInfo.tick)
end

if driver and driver.runAll then
	driver:runAll()
end

clock:set(clock:now() + 0.25)
local snap = Renderer.render(runtime, adapter.palette, clock:now())
DebugViz.snapshot(snap, { label = "three_circles_final", logSnapshots = true })

if previousEmitter then
	Log.setEmitter(previousEmitter)
end
