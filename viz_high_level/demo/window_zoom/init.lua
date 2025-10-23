local WindowZoomDemo = {}

local Query = require("Query")
local SchemaHelpers = require("tests.support.schema_helpers")
local Scheduler = require("viz_high_level.demo.scheduler")

local function buildSubjects()
	local customersSubject, customers = SchemaHelpers.subjectWithSchema("customers", {
		idField = "id",
	})
	local ordersSubject, orders = SchemaHelpers.subjectWithSchema("orders", { idField = "id" })

	local builder = Query.from(customers, "customers")
		:leftJoin(orders, "orders")
		:onSchemas({ customers = "id", orders = "customerId" })
		:window({ count = 20 })

	return {
		builder = builder,
		subjects = {
			customers = customersSubject,
			orders = ordersSubject,
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

	local function addMatchedPairs(startTick)
		local tick = startTick
		local ids = { 1, 3, 5, 7, 9, 11, 13, 15 }
		for _, id in ipairs(ids) do
			emit(tick, "customers", {
				id = id,
				name = string.format("Cust %d", id),
			})
			emit(tick + 0.4, "orders", {
				id = 1000 + id,
				customerId = id,
				total = 25 + (id % 4) * 5,
			})
			tick = tick + 0.9
		end
		return tick
	end

	-- Explainer: ten gentle bursts of 11 orders push the active id count above 100 to
	-- trigger the large 100x100 zoom without overwhelming the viewer.
	local function addLargeBurst(opts)
		opts = opts or {}
		local tick = opts.startTick or 0
		local startOrderId = opts.startOrderId or 200
		local customerBase = opts.customerBase or 4000
		local bursts = opts.bursts or 10
		local perBurst = opts.perBurst or 11
		local burstSpacing = opts.burstSpacing or 1
		local intraSpacing = opts.intraSpacing or 0.03

		for burst = 0, bursts - 1 do
			local baseTick = tick + burst * burstSpacing
			local offset = burst * perBurst
			for i = 0, perBurst - 1 do
				emit(baseTick + (i * intraSpacing), "orders", {
					id = startOrderId + offset + i,
					customerId = customerBase + offset + i,
					total = 40 + ((i + burst) % 5) * 4,
				})
			end
		end

		return tick + (bursts - 1) * burstSpacing + 0.6
	end

	-- Explainer: after the big burst has faded, sprinkle a handful of higher ids so the
	-- 10x10 window slides forward with its 20% buffer clearly visible.
	local function addSlideProbers(opts)
		opts = opts or {}
		local tick = opts.startTick or 0
		local startId = opts.startId or 320
		local step = opts.step or 12
		local count = opts.count or 12
		local spacing = opts.spacing or 0.6

		for i = 0, count - 1 do
			local id = startId + (i * step)
			emit(tick + (i * spacing), "orders", {
				id = id,
				customerId = id + 10000,
				total = 15 + (i % 3) * 3,
			})
		end

		return tick + (count - 1) * spacing
	end

	-- Stage A: short, fully matched flow that stays inside the 10x10 view.
	local afterPairs = addMatchedPairs(0)
	snapshots[#snapshots + 1] = { tick = afterPairs + 0.2, label = "small_start" }

	-- Stage B: controlled burst that trips auto-zoom to 100x100.
	local afterBurst = addLargeBurst({
		startTick = afterPairs + 1.2,
		bursts = 10,
		perBurst = 11,
		burstSpacing = 1,
		intraSpacing = 0.05,
		startOrderId = 200,
		customerBase = 5000,
	})
	snapshots[#snapshots + 1] = { tick = afterBurst, label = "large_burst" }

	-- Stage C: idle long enough for the burst to decay, then nudge the window forward.
	local afterCooldown = afterBurst + 12
	snapshots[#snapshots + 1] = { tick = afterCooldown, label = "cooled_small" }
	local afterSlide = addSlideProbers({
		startTick = afterCooldown + 0.5,
		startId = 320,
		step = 14,
		count = 12,
		spacing = 0.7,
	})
	snapshots[#snapshots + 1] = { tick = afterSlide, label = "slide_buffer" }

	-- Stage D: final lull to let everything fade, showing the 10x10 zoom return.
	local finishTick = afterSlide + 10
	command(finishTick, "complete")
	snapshots[#snapshots + 1] = { tick = finishTick, label = "final_small" }

	return events, snapshots
end

local WINDOW_EVENTS, WINDOW_SNAPSHOTS = buildTimeline()

---@return table
function WindowZoomDemo.build()
	return buildSubjects()
end

---@param subjects table
function WindowZoomDemo.complete(subjects)
	for _, subject in pairs(subjects or {}) do
		if subject.onCompleted then
			subject:onCompleted()
		end
	end
end

---@param subjects table
---@param opts table|nil
---@return table driver
function WindowZoomDemo.start(subjects, opts)
	opts = opts or {}
	local ticksPerSecond = opts.ticksPerSecond or 1.2
	local clock = opts.clock

	local scheduler
	local function stampTick(event)
		if clock and clock.set then
			local tick = event.tick or (scheduler and scheduler:currentTick()) or 0
			clock:set(tick)
		end
	end

	scheduler = Scheduler.new({
		events = WINDOW_EVENTS,
		handlers = {
			emit = function(event)
				stampTick(event)
				local subject = subjects[event.schema]
				assert(subject, string.format("Unknown schema %s in window_zoom demo", tostring(event.schema)))
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
				WindowZoomDemo.complete(subjects)
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
		WindowZoomDemo.complete(subjects)
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

WindowZoomDemo.snapshots = WINDOW_SNAPSHOTS
WindowZoomDemo.timeline = WINDOW_EVENTS
WindowZoomDemo.loveDefaults = {
	label = "window zoom",
	ticksPerSecond = 1.2,
	visualsTTL = 2.5,
	adjustInterval = 0.5,
	visualsTTLCooldown = 12,
}

return WindowZoomDemo
