local ThreeCirclesDemo = {}

local Query = require("LQR.Query")
local SchemaHelpers = require("tests.support.schema_helpers")
local ZonesTimeline = require("vizualisation.demo.common.zones_timeline")
local Driver = require("vizualisation.demo.common.driver")
local LoveDefaults = require("vizualisation.demo.common.love_defaults")
local Log = require("util.log").withTag("demo")

local PLAY_DURATION = 20
local JOINT_TTL = 5
local demoClock = {
	value = 0,
	now = function(self)
		return self.value or 0
	end,
	set = function(self, v)
		self.value = v or 0
	end,
}

local function retentionWindow()
	return {
		time = JOINT_TTL,
		field = "sourceTime",
		currentFn = function()
			return demoClock:now()
		end,
		gcIntervalSeconds = math.max(0.1, JOINT_TTL / 4),
	}
end

local function build()
	local customersSubject, customers = SchemaHelpers.subjectWithSchema("customers", { idField = "id" })
	local ordersSubject, orders = SchemaHelpers.subjectWithSchema("orders", { idField = "id" })
	local shipmentsSubject, shipments = SchemaHelpers.subjectWithSchema("shipments", { idField = "id" })

	local builder = Query
		.from(customers, "customers")
		--:distinct("customers", { by = "loyaltyTier", window = retentionWindow() })
		:innerJoin(orders, "orders")
		:on({
			customers = { field = "id", oneShot = true },
			orders = { field = "customerId", oneShot = true },
		})
		:innerJoin(shipments, "shipments")
		:on({
			orders = { field = "id", oneShot = true },
			shipments = { field = "orderId", oneShot = true },
		})
		:withDefaultJoinWindow(retentionWindow())

	-- Group orders per customer over a short window to illustrate aggregate + HAVING.
	-- We keep both aggregate and enriched views available for logging.
	local groupedAggregate = builder
		:groupBy("orders_per_customer", function(row)
			return row.customers.id
		end)
		:groupWindow({ time = 25, field = "sourceTime" })
		:aggregates({
			count = true,
			sum = { "customers.orders.total" },
			avg = { "customers.orders.total" },
		})
		:having(function(g)
			-- Keep all groups (threshold 1) so the demo always emits aggregates.
			return g._count >= 1
		end)

	local groupedEnriched = builder
		:groupByEnrich("_groupBy:customers", function(row)
			return row.customers.id
		end)
		:groupWindow({ time = 25, field = "sourceTime" })
		:aggregates({
			count = true,
			sum = { "customers.orders.total" },
			avg = { "customers.orders.total" },
		})
		:having(function(row)
			return row._count >= 1
		end)

	-- Console/info logging to observe aggregates without a visual component.
	groupedAggregate:subscribe(function(row)
		local sum = row.customers and row.customers.orders and row.customers.orders._sum
		local avg = row.customers and row.customers.orders and row.customers.orders._avg
		Log:info(
			"[agg][cust=%s] count=%s sum=%s avg=%s schema=%s",
			tostring(row.RxMeta and row.RxMeta.groupKey),
			tostring(row._count),
			tostring(sum and sum.total),
			tostring(avg and avg.total),
			tostring(row.RxMeta and row.RxMeta.schema)
		)
	end)

	groupedEnriched:subscribe(function(row)
		local sum = row.customers and row.customers.orders and row.customers.orders._sum
		local avg = row.customers and row.customers.orders and row.customers.orders._avg
		Log:info(
			"[enr][cust=%s] count=%s latestOrderTotal=%s sum=%s avg=%s",
			tostring(row.RxMeta and row.RxMeta.groupKey),
			tostring(row._count),
			tostring(row.orders and row.orders.total),
			tostring(sum and sum.total),
			tostring(avg and avg.total)
		)
	end)

	return {
		subjects = {
			customers = customersSubject,
			orders = ordersSubject,
			shipments = shipmentsSubject,
		},
		builder = builder,
		groupedAggregate = groupedAggregate,
		groupedEnriched = groupedEnriched,
	}
end

local function buildZones()
	return {
		{
			label = "cust_circle",
			schema = "customers",
			center = 1020,
			range = 1,
			radius = 7,
			shape = "circle10",
			coverage = 1,
			mode = "random",
			rate = 20,
			t0 = 0.05,
			t1 = 0.8,
			rate_shape = "constant",
			idField = "id",
			payloadForId = function(id)
				local tiers = { "bronze", "silver", "gold" }
				local regions = { "north", "south", "east", "west" }
				return {
					id = id,
					loyaltyTier = tiers[(id % #tiers) + 1],
					region = regions[(id % #regions) + 1],
				}
			end,
		},
		{
			label = "ord_circle",
			schema = "orders",
			center = 1312,
			range = 1,
			radius = 7,
			shape = "circle10",
			coverage = 1,
			mode = "random",
			rate = 20,
			t0 = 0.05,
			t1 = 0.8,
			rate_shape = "constant",
			idField = "id",
			payloadForId = function(id)
				local channels = { "web", "store", "mobile" }
				local payment = { "card", "cash" }
				return {
					id = id,
					customerId = id,
					total = 20 + ((id % 5) * 15),
					channel = channels[(id % #channels) + 1],
					paymentMethod = payment[(id % #payment) + 1],
				}
			end,
		},
		{
			label = "ship_circle",
			schema = "shipments",
			center = 1520,
			range = 1,
			radius = 7,
			shape = "circle10",
			coverage = 1,
			mode = "random",
			rate = 20,
			t0 = 0.4,
			t1 = 0.8,
			rate_shape = "constant",
			idField = "id",
			payloadForId = function(id)
				local regions = { "north_dc", "south_dc" }
				local sizes = { "small", "medium", "large" }
				return {
					id = id,
					orderId = id,
					carrier = "c" .. (id % 3),
					status = "in_transit",
					warehouse = regions[(id % #regions) + 1],
					packageSize = sizes[(id % #sizes) + 1],
				}
			end,
		},
	}
end

local function buildTimeline()
	local zones = buildZones()
	-- Keep the zone generator aligned with the viewport: 100x100 window starting at id 0.
	local grid = { startId = 0, columns = 100, rows = 100 }
	return ZonesTimeline.build(zones, {
		totalPlaybackTime = PLAY_DURATION,
		completeDelay = 0.5,
		grid = grid,
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
function ThreeCirclesDemo.build()
	return build()
end

---@param subjects table
function ThreeCirclesDemo.complete(subjects)
	for _, subject in pairs(subjects or {}) do
		if subject.onCompleted then
			subject:onCompleted()
		end
	end
end

---@param subjects table
---@param opts table|nil
---@return table driver
function ThreeCirclesDemo.start(subjects, opts)
	opts = opts or {}
	local ticksPerSecond = opts.playbackSpeed or opts.ticksPerSecond or 2
	local clock = opts.clock or demoClock
	demoClock = clock
	local events, snapshots, summary = buildTimeline()
	ThreeCirclesDemo.snapshots = snapshots
	ThreeCirclesDemo.timeline = events
	ThreeCirclesDemo.summary = summary

	return Driver.new({
		events = events,
		subjects = subjects,
		ticksPerSecond = ticksPerSecond,
		clock = clock,
		label = "three_circles",
		onCompleteAll = ThreeCirclesDemo.complete,
	})
end

ThreeCirclesDemo.loveDefaults = LoveDefaults.merge({
	label = "three circles",
	visualsTTLFactor = 1.2,
	visualsTTLFactors = {
		-- NOTE: "joined" refers to join layers; "final" controls the outer post-WHERE ring.
		source = 1.0,
		joined = 1.5,
		final = 7,
		expire = 0.02,
	},
	visualsTTLLayerFactors = {
		-- Layer 1 = final ring, layers 2+ = join rings for this demo.
		[1] = 1,
		[2] = 1,
		[3] = 1,
	},
	playbackSpeed = 0.7,
	visualsTTL = JOINT_TTL,
	adjustInterval = 0.25,
	clockMode = "driver",
	clockRate = 1,
	totalPlaybackTime = PLAY_DURATION,
	maxColumns = 100,
	maxRows = 100,
	startId = 0,
	lockWindow = true,
})

return ThreeCirclesDemo
