local TwoCirclesDemo = {}

local Query = require("Query")
local SchemaHelpers = require("tests.support.schema_helpers")
local ZonesTimeline = require("viz_high_level.demo.common.zones_timeline")
local Driver = require("viz_high_level.demo.common.driver")
local LoveDefaults = require("viz_high_level.demo.common.love_defaults")
local Log = require("log").withTag("demo")

local PLAY_DURATION = 20
local JOINT_TTL = 3
local demoClock = {
	value = 0,
	now = function(self)
		return self.value or 0
	end,
	set = function(self, v)
		self.value = v or 0
	end,
}

local function build()
	-- Subjects are wrapped with schema metadata so QueryVizAdapter can resolve keys.
	-- Payloads flow through untouched; idField only matters if payloadForId is absent.
	local customersSubject, customers = SchemaHelpers.subjectWithSchema("customers", { idField = "id" })
	local ordersSubject, orders = SchemaHelpers.subjectWithSchema("orders", { idField = "id" })

	local builder = Query.from(customers, "customers")
		:innerJoin(orders, "orders")
		:onSchemas({
			customers = { field = "id", bufferSize = 10 },
			orders = { field = "customerId", bufferSize = 10 },
		})
		:window({
			time = JOINT_TTL,
			field = "sourceTime",
			currentFn = function()
				return demoClock:now()
			end,
		})

	return {
		subjects = {
			customers = customersSubject,
			orders = ordersSubject,
		},
		builder = builder,
	}
end

local function buildZones()
	return {
		-- Single circle overlap.
		{
			label = "cust_circle",
			schema = "customers",
			center = 44,
			range = 1, --invalid for circle shapes
			radius = 2,
			shape = "circle10",
			coverage = 1,
			mode = "random",
			rate = 8,
			t0 = 0.1,
			t1 = 0.7,
			rate_shape = "constant",
			idField = "id",
		},
		{
			label = "ord_circle",
			schema = "orders",
			center = 46,
			range = 1, --invalid for circle shapes
			radius = 2,
			shape = "circle10",
			coverage = 1,
			mode = "random",
			rate = 8,
			t0 = 0.1,
			t1 = 0.7,
			rate_shape = "constant",
			idField = "id",
			payloadForId = function(id)
				return { id = id, orderId = 500 + id, customerId = id, total = 30 + ((id % 4) * 5) }
			end,
		},
	}
end

local function buildTimeline()
	local zones = buildZones()
	return ZonesTimeline.build(zones, {
		totalPlaybackTime = PLAY_DURATION,
		completeDelay = 0.5,
		grid = { startId = 0, columns = 10, rows = 10 },
		stampSourceTime = true,
		clock = demoClock,
		debug = {
			logger = function(msg)
				Log:debug("%s", msg)
			end,
		},
		snapshots = {
			{ tick = PLAY_DURATION * 0.2, label = "rise" },
			{ tick = PLAY_DURATION * 0.55, label = "mix" },
			{ tick = PLAY_DURATION * 0.9, label = "trail" },
		},
	})
end

---@return table
function TwoCirclesDemo.build()
	return build()
end

---@param subjects table
function TwoCirclesDemo.complete(subjects)
	for _, subject in pairs(subjects or {}) do
		if subject.onCompleted then
			subject:onCompleted()
		end
	end
end

---@param subjects table
---@param opts table|nil
---@return table driver
function TwoCirclesDemo.start(subjects, opts)
	opts = opts or {}
	local ticksPerSecond = opts.playbackSpeed or opts.ticksPerSecond or 2
	local clock = opts.clock or demoClock
	demoClock = clock
	local events, snapshots, summary = buildTimeline()
	TwoCirclesDemo.snapshots = snapshots
	TwoCirclesDemo.timeline = events
	TwoCirclesDemo.summary = summary

	return Driver.new({
		events = events,
		subjects = subjects,
		ticksPerSecond = ticksPerSecond,
		clock = clock,
		label = "two_circles",
		onCompleteAll = TwoCirclesDemo.complete,
	})
end

TwoCirclesDemo.loveDefaults = LoveDefaults.merge({
	label = "two circles",
	visualsTTLFactor = 1.2,
	visualsTTLFactors = {
		source = 1.1,
		match = 7.2,
		expire = 0.1,
	},
	visualsTTLLayerFactors = {
		[1] = 1.0,
		[2] = 1.3,
	},
	playbackSpeed = 0.7,
	visualsTTL = JOINT_TTL,
	adjustInterval = 0.25,
	clockMode = "driver",
	clockRate = 1,
	totalPlaybackTime = PLAY_DURATION,
	maxColumns = 10,
	maxRows = 10,
	startId = 0,
	lockWindow = true,
})

return TwoCirclesDemo
