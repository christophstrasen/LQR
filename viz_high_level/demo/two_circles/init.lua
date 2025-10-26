local TwoCirclesDemo = {}

local Query = require("Query")
local SchemaHelpers = require("tests.support.schema_helpers")
local ZonesTimeline = require("viz_high_level.demo.common.zones_timeline")
local Driver = require("viz_high_level.demo.common.driver")

local PLAY_DURATION = 10

local function build()
	-- Subjects are wrapped with schema metadata so QueryVizAdapter can resolve keys.
	-- Payloads flow through untouched; idField only matters if payloadForId is absent.
	local customersSubject, customers = SchemaHelpers.subjectWithSchema("customers", { idField = "id" })
	local ordersSubject, orders = SchemaHelpers.subjectWithSchema("orders", { idField = "id" })

	local builder = Query.from(customers, "customers")
		:innerJoin(orders, "orders")
		:onSchemas({ customers = "id", orders = "customerId" })
		:window({ count = 20 })

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
			center = 45,
			range = 1,
			radius = 7,
			shape = "circle10",
			coverage = 0.3,
			mode = "random",
			rate = 8,
			t0 = 0.0,
			t1 = 0.5,
			rate_shape = "bell",
			idField = "id",
		},
		{
			label = "ord_circle",
			schema = "orders",
			center = 55,
			range = 1,
			radius = 7,
			shape = "circle10",
			coverage = 0.2,
			mode = "random",
			rate = 8,
			t0 = 0.1,
			t1 = 0.6,
			rate_shape = "linear_down",
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
		snapshots = {
			{ tick = PLAY_DURATION * 0.2, label = "rise" },
			{ tick = PLAY_DURATION * 0.55, label = "mix" },
			{ tick = PLAY_DURATION * 0.9, label = "trail" },
		},
	})
end

local TWO_CIRCLES_EVENTS, TWO_CIRCLES_SNAPSHOTS, TWO_CIRCLES_SUMMARY = buildTimeline()

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
	local ticksPerSecond = opts.ticksPerSecond or 2
	local clock = opts.clock

	return Driver.new({
		events = TWO_CIRCLES_EVENTS,
		subjects = subjects,
		ticksPerSecond = ticksPerSecond,
		clock = clock,
		label = "two_circles",
		onCompleteAll = TwoCirclesDemo.complete,
	})
end

TwoCirclesDemo.snapshots = TWO_CIRCLES_SNAPSHOTS
TwoCirclesDemo.timeline = TWO_CIRCLES_EVENTS
TwoCirclesDemo.summary = TWO_CIRCLES_SUMMARY
TwoCirclesDemo.loveDefaults = {
	label = "two circles",
	ticksPerSecond = 2,
	visualsTTL = 15,
	adjustInterval = 0.5,
	totalPlaybackTime = PLAY_DURATION,
	maxColumns = 10,
	maxRows = 10,
	startId = 0,
	lockWindow = true,
}

return TwoCirclesDemo
