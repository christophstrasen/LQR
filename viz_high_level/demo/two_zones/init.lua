local TwoZonesDemo = {}

local Query = require("Query")
local SchemaHelpers = require("tests.support.schema_helpers")
local Scheduler = require("viz_high_level.demo.scheduler")
local Zones = require("viz_high_level.zones")

local PLAY_DURATION = 12

local function buildSubjects()
	local customersSubject, customers = SchemaHelpers.subjectWithSchema("customers", { idField = "id" })
	local ordersSubject, orders = SchemaHelpers.subjectWithSchema("orders", { idField = "id" })

	local builder = Query.from(customers, "customers")
		:leftJoin(orders, "orders")
		:onSchemas({ customers = "id", orders = "customerId" })
		:window({ count = 16 })

	return {
		builder = builder,
		subjects = {
			customers = customersSubject,
			orders = ordersSubject,
		},
	}
end

local function buildZones()
	return {
		-- Zone A: tight overlap to show immediate matches near 100.
		{
			label = "cust_a",
			schema = "customers",
			center = 100,
			radius = 3,
			shape = "flat",
			density = 1.0,
			t0 = 0.0,
			t1 = 0.35,
			rate_shape = "linear_up",
			idField = "id",
		},
		{
			label = "ord_a",
			schema = "orders",
			center = 100,
			radius = 3,
			shape = "flat",
			density = 1.0,
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
			center = 200,
			radius = 5,
			shape = "linear_in",
			density = 0.6,
			t0 = 0.45,
			t1 = 0.9,
			rate_shape = "bell",
			idField = "id",
		},
		{
			label = "ord_b",
			schema = "orders",
			center = 210,
			radius = 4,
			shape = "bell",
			density = 0.5,
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
	local events, summary = Zones.generator.generate(zones, {
		totalPlaybackTime = PLAY_DURATION,
		playStart = 0,
	})

	events[#events + 1] = { tick = PLAY_DURATION + 0.5, kind = "complete" }

	local snapshots = {
		{ tick = PLAY_DURATION * 0.25, label = "early_overlap" },
		{ tick = PLAY_DURATION * 0.6, label = "mid_blend" },
		{ tick = PLAY_DURATION * 0.95, label = "late_shift" },
	}

	return events, snapshots, summary
end

local TWO_ZONES_EVENTS, TWO_ZONES_SNAPSHOTS = buildTimeline()

---@return table
function TwoZonesDemo.build()
	return buildSubjects()
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
	local ticksPerSecond = opts.ticksPerSecond or 2
	local clock = opts.clock

	local scheduler
	local function stampTick(event)
		if clock and clock.set then
			local tick = event.tick or (scheduler and scheduler:currentTick()) or 0
			clock:set(tick)
		end
	end

	scheduler = Scheduler.new({
		events = TWO_ZONES_EVENTS,
		handlers = {
			emit = function(event)
				stampTick(event)
				local subject = subjects[event.schema]
				assert(subject, string.format("Unknown schema %s in two_zones demo", tostring(event.schema)))
				subject:onNext(event.payload)
			end,
			complete = function(event)
				stampTick(event)
				if event.schema then
					local subject = subjects[event.schema]
					if subject and subject.onCompleted then
						subject:onCompleted()
					end
					return
				end
				TwoZonesDemo.complete(subjects)
			end,
		},
	})

	local driver = {
		scheduler = scheduler,
		finished = scheduler:isFinished(),
	}

	local function finalize()
		if driver.finished then
			return
		end
		TwoZonesDemo.complete(subjects)
		driver.finished = true
	end

	function driver:update(dt)
		if driver.finished then
			return
		end
		local deltaTicks = math.max(0, (dt or 0) * ticksPerSecond)
		scheduler:advance(deltaTicks)
		if scheduler:isFinished() then
			finalize()
		end
	end

	function driver:runUntil(targetTick)
		if driver.finished then
			return
		end
		scheduler:runUntil(targetTick)
		if scheduler:isFinished() then
			finalize()
		end
	end

	function driver:runAll()
		if driver.finished then
			return
		end
		scheduler:drain()
		finalize()
	end

	function driver:isFinished()
		return driver.finished
	end

	function driver:currentTick()
		return scheduler:currentTick()
	end

	return driver
end

TwoZonesDemo.snapshots = TWO_ZONES_SNAPSHOTS
TwoZonesDemo.timeline = TWO_ZONES_EVENTS
TwoZonesDemo.loveDefaults = {
	label = "two zones",
	ticksPerSecond = 2,
	visualsTTL = 4,
	adjustInterval = 0.5,
	totalPlaybackTime = PLAY_DURATION,
}

return TwoZonesDemo
