local TwoZonesDemo = {}

local Query = require("Query")
local SchemaHelpers = require("tests.support.schema_helpers")
local ZonesTimeline = require("viz_high_level.demo.common.zones_timeline")
local Driver = require("viz_high_level.demo.common.driver")

local PLAY_DURATION = 12

local function build()
	local customersSubject, customers = SchemaHelpers.subjectWithSchema("customers", { idField = "id" })
	local ordersSubject, orders = SchemaHelpers.subjectWithSchema("orders", { idField = "id" })

	local builder = Query.from(customers, "customers")
		:leftJoin(orders, "orders")
		:onSchemas({ customers = "id", orders = "customerId" })
		:window({ count = 16 })

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
		-- Zone A: tight overlap to show immediate matches near 100.
		{
			label = "cust_a",
			schema = "customers",
			center = 10,
			range = 3,
			shape = "continuous",
			coverage = 1.0,
			mode = "random",
			rate = 10,
			t0 = 0.0,
			t1 = 0.35,
			rate_shape = "linear_up",
			idField = "id",
		},
		{
			label = "ord_a",
			schema = "orders",
			center = 30,
			range = 3,
			shape = "continuous",
			coverage = 1.0,
			mode = "random",
			rate = 10,
			t0 = 0.15,
			t1 = 0.5,
			rate_shape = "linear_down",
			idField = "id",
			payloadForId = function(id)
				return { id = 1000 + id, customerId = id, total = 25 + ((id % 3) * 5) }
			end,
		},

		-- Zone B: shifted overlap to show partial matches and progression.
		{
			label = "cust_b",
			schema = "customers",
			center = 50,
			range = 5,
			shape = "linear_in",
			coverage = 0.6,
			mode = "random",
			rate = 8,
			t0 = 0.45,
			t1 = 0.9,
			rate_shape = "bell",
			idField = "id",
		},
		{
			label = "ord_b",
			schema = "orders",
			center = 60,
			range = 4,
			shape = "bell",
			coverage = 0.5,
			mode = "random",
			rate = 8,
			t0 = 0.55,
			t1 = 1.0,
			rate_shape = "linear_up",
			idField = "id",
			payloadForId = function(id)
				return { id = 2000 + id, customerId = id - 5, total = 40 + ((id % 4) * 4) }
			end,
		},
	}
end

local function buildTimeline()
	local zones = buildZones()
	return ZonesTimeline.build(zones, {
		totalPlaybackTime = PLAY_DURATION,
		completeDelay = 0.5,
		snapshots = {
			{ tick = PLAY_DURATION * 0.25, label = "early_overlap" },
			{ tick = PLAY_DURATION * 0.6, label = "mid_blend" },
			{ tick = PLAY_DURATION * 0.95, label = "late_shift" },
		},
	})
end

local TWO_ZONES_EVENTS, TWO_ZONES_SNAPSHOTS, TWO_ZONES_SUMMARY = buildTimeline()

---@return table
function TwoZonesDemo.build()
	return build()
end

---@param subjects table
function TwoZonesDemo.complete(subjects)
	for _, subject in pairs(subjects or {}) do
		if subject.onCompleted then
			subject:onCompleted()
		end
	end
end

---@param subjects table
---@param opts table|nil
---@return table driver
function TwoZonesDemo.start(subjects, opts)
	opts = opts or {}
	local ticksPerSecond = opts.playbackSpeed or opts.ticksPerSecond or 2
	local clock = opts.clock

	return Driver.new({
		events = TWO_ZONES_EVENTS,
		subjects = subjects,
		ticksPerSecond = ticksPerSecond,
		clock = clock,
		label = "two_zones",
		onCompleteAll = TwoZonesDemo.complete,
	})
end

TwoZonesDemo.snapshots = TWO_ZONES_SNAPSHOTS
TwoZonesDemo.timeline = TWO_ZONES_EVENTS
TwoZonesDemo.summary = TWO_ZONES_SUMMARY
TwoZonesDemo.loveDefaults = {
	label = "two zones",
	playbackSpeed = 2,
	visualsTTL = 4,
	adjustInterval = 0.5,
	clockMode = "driver",
	clockRate = 2,
	totalPlaybackTime = PLAY_DURATION,
}

return TwoZonesDemo
