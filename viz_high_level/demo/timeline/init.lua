local TimelineDemo = {}

local Query = require("Query")
local SchemaHelpers = require("tests.support.schema_helpers")
local Scheduler = require("viz_high_level.demo.scheduler")
local LoveDefaults = require("viz_high_level.demo.common.love_defaults")

local function buildSubjects()
	local customersSubject, customers = SchemaHelpers.subjectWithSchema("customers", { idField = "id" })
	local ordersSubject, orders = SchemaHelpers.subjectWithSchema("orders", { idField = "id" })
	local shipmentsSubject, shipments = SchemaHelpers.subjectWithSchema("shipments", { idField = "id" })

	local builder = Query.from(customers, "customers")
		:leftJoin(orders, "orders")
		:onSchemas({ customers = "id", orders = "customerId" })
		:leftJoin(shipments, "shipments")
		:onSchemas({ orders = "id", shipments = "orderId" })
		:window({ count = 16 })

	return {
		builder = builder,
		subjects = {
			customers = customersSubject,
			orders = ordersSubject,
			shipments = shipmentsSubject,
		},
	}
end

local function buildTimeline()
	local events = {}
	local snapshots = {}

	local function emit(tick, schema, payload)
		events[#events + 1] = { tick = tick, schema = schema, payload = payload }
	end

	local function command(tick, kind, extra)
		local evt = { tick = tick, kind = kind }
		if extra then
			for k, v in pairs(extra) do
				evt[k] = v
			end
		end
		events[#events + 1] = evt
	end

	local function addOrderBurst(args)
		local tick = args.startTick or 0
		local tickStep = args.tickStep or 0.08
		for i = 0, (args.count or 0) - 1 do
			emit(tick + i * tickStep, "orders", {
				id = (args.startOrderId or 0) + i,
				customerId = (args.startCustomerId or 0) + i,
				total = 40 + ((i % 7) * 5),
			})
		end
		return tick + (args.count or 0) * tickStep
	end

	local function addShipmentWave(startTick, orderIds, spacing)
		for i, orderId in ipairs(orderIds or {}) do
			emit(startTick + (i - 1) * (spacing or 0.25), "shipments", {
				id = 1500 + orderId,
				orderId = orderId,
				carrier = "Wave",
			})
		end
	end

	local function addCustomers(startTick, ids, spacing)
		for i, id in ipairs(ids or {}) do
			emit(startTick + (i - 1) * (spacing or 0.3), "customers", {
				id = id,
				name = string.format("Customer %d", id),
			})
		end
	end

	-- Stage 1: warm-up with a few matches + orphans.
	emit(0, "customers", { id = 10, name = "Ada" })
	emit(0.5, "orders", { id = 101, customerId = 10, total = 96 })
	emit(1, "shipments", { id = 301, orderId = 101, carrier = "Mach" })
	emit(1.5, "customers", { id = 20, name = "Ben" })
	emit(2, "orders", { id = 205, customerId = 40, total = 12 }) -- waits for customer 40
	emit(2.5, "orders", { id = 206, customerId = 20, total = 33 })
	emit(3, "shipments", { id = 320, orderId = 206, carrier = "Raven" })
	emit(3.5, "shipments", { id = 321, orderId = 999, carrier = "Lost" }) -- orphaned shipment
	emit(4, "customers", { id = 30, name = "Cara" })
	emit(4.5, "orders", { id = 230, customerId = 30, total = 54 })
	emit(5, "shipments", { id = 330, orderId = 230, carrier = "Bike" })
	emit(5.5, "customers", { id = 50, name = "Dia" })
	emit(6, "orders", { id = 502, customerId = 50, total = 42 })
	emit(6.5, "shipments", { id = 650, orderId = 9998, carrier = "Ghost" })

	snapshots[#snapshots + 1] = { tick = 6.5, label = "warmup" }

	-- Stage 2: large burst of orders with diverse customer ids to force expansion.
	local afterBurst1 = addOrderBurst({
		startTick = 7,
		startOrderId = 400,
		startCustomerId = 60,
		count = 60,
		tickStep = 0.08,
	})
	local afterBurst2 = addOrderBurst({
		startTick = afterBurst1 + 0.5,
		startOrderId = 800,
		startCustomerId = 200,
		count = 50,
		tickStep = 0.08,
	})
	emit(afterBurst2 + 0.5, "orders", { id = 950, customerId = 450, total = 120 })

	snapshots[#snapshots + 1] = { tick = afterBurst1, label = "burst_one" }
	snapshots[#snapshots + 1] = { tick = afterBurst2, label = "burst_two" }

	-- Stage 3: shipments land on subsets of the burst to light up join layers.
	addShipmentWave(afterBurst1 + 0.25, { 400, 405, 412, 430, 448, 458 }, 0.25)
	addShipmentWave(afterBurst2 + 0.25, { 805, 812, 820, 833, 845, 880 }, 0.25)
	emit(afterBurst2 + 1.5, "shipments", { id = 2000, orderId = 950, carrier = "Priority" })
	emit(afterBurst2 + 1.6, "shipments", { id = 2001, orderId = 4400, carrier = "Errant" }) -- unmatched

	-- Stage 4: delayed customers arrive to retro-match earlier orders.
	addCustomers(afterBurst2 + 2, { 40, 60, 65, 70, 90, 110, 150, 200, 210, 225, 230, 240, 450 }, 0.35)

	snapshots[#snapshots + 1] = { tick = afterBurst2 + 2.5, label = "retro_matches" }

	-- Stage 5: lull to let cache decay, then low-id inserts to trigger contraction.
	local lowStart = afterBurst2 + 7
	emit(lowStart, "orders", { id = 120, customerId = 12, total = 15 })
	emit(lowStart + 0.3, "customers", { id = 12, name = "Lana" })
	emit(lowStart + 0.6, "shipments", { id = 5000, orderId = 120, carrier = "Bike" })
	emit(lowStart + 1.2, "orders", { id = 222, customerId = 25, total = 22 })
	emit(lowStart + 1.5, "customers", { id = 25, name = "Moe" })
	emit(lowStart + 1.8, "shipments", { id = 5001, orderId = 222, carrier = "Bike" })
	emit(lowStart + 2.2, "orders", { id = 150, customerId = 15, total = 11 })
	emit(lowStart + 2.5, "shipments", { id = 5002, orderId = 150, carrier = "Bike" })
	emit(lowStart + 2.8, "customers", { id = 15, name = "Nia" })
	emit(lowStart + 3.2, "orders", { id = 360, customerId = 65, total = 39 })
	emit(lowStart + 3.5, "shipments", { id = 5003, orderId = 360, carrier = "Bike" })

	snapshots[#snapshots + 1] = { tick = lowStart + 2.5, label = "contraction" }

	command(lowStart + 6, "complete")

	snapshots[#snapshots + 1] = { tick = lowStart + 6, label = "final" }

	return events, snapshots
end

local TIMELINE_EVENTS, TIMELINE_SNAPSHOTS = buildTimeline()

---@return table
function TimelineDemo.build()
	return buildSubjects()
end

---@param subjects table
function TimelineDemo.complete(subjects)
	for _, subject in pairs(subjects or {}) do
		if subject.onCompleted then
			subject:onCompleted()
		end
	end
end

---@param subjects table
---@param opts table|nil
---@return table driver
function TimelineDemo.start(subjects, opts)
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
		events = TIMELINE_EVENTS,
		handlers = {
			emit = function(event)
				stampTick(event)
				local subject = subjects[event.schema]
				assert(subject, string.format("Unknown schema %s in timeline demo", tostring(event.schema)))
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
				TimelineDemo.complete(subjects)
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
		TimelineDemo.complete(subjects)
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

TimelineDemo.snapshots = TIMELINE_SNAPSHOTS
TimelineDemo.timeline = TIMELINE_EVENTS
TimelineDemo.loveDefaults = LoveDefaults.merge({
	label = "timeline",
	ticksPerSecond = 2.5,
	visualsTTL = 10,
})

return TimelineDemo
