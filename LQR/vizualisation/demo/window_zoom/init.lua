local WindowZoomDemo = {}

local Query = require("LQR.Query")
local SchemaHelpers = require("LQR.tests.support.schema_helpers")
local Scheduler = require("LQR.vizualisation.demo.scheduler")
local LoveDefaults = require("LQR.vizualisation.demo.common.love_defaults")

local function buildSubjects()
	local customersSubject, customers = SchemaHelpers.subjectWithSchema("customers", {
		idField = "id",
	})
	local ordersSubject, orders = SchemaHelpers.subjectWithSchema("orders", { idField = "id" })

	local builder = Query.from(customers, "customers")
		:leftJoin(orders, "orders")
		:on({
			customers = { field = "id", bufferSize = 10 },
			orders = { field = "customerId", bufferSize = 10 },
		})
		:joinWindow({ count = 20 })

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

	-- Explainer: emit a sparse burst of orders spaced ~idStep apart so span crosses the
	-- 10x10 window and forces the large zoom without flooding the stream. Spacing accelerates
	-- from spacingStart to spacingEnd to ease the viewer in.
	local function addLargeBurst(opts)
		opts = opts or {}
		local tick = opts.startTick or 0
		local startOrderId = opts.startOrderId or 200
		local startCustomerId = opts.startCustomerId or 5000
		local count = opts.count or 10
		if count <= 0 then
			return tick
		end
		local idStep = opts.idStep or 10
		local spacingStart = opts.spacingStart or 0.5
		local spacingEnd = opts.spacingEnd or 0.1

		local function lerp(a, b, t)
			if t < 0 then
				t = 0
			elseif t > 1 then
				t = 1
			end
			return a + (b - a) * t
		end

		for i = 0, count - 1 do
			local t = (count <= 1) and 0 or (i / (count - 1))
			local spacing = lerp(spacingStart, spacingEnd, t)
			local id = startOrderId + (i * idStep)
			emit(tick, "orders", {
				id = id,
				-- Project onto a tight customer band: offset by position, not by full order id.
				customerId = startCustomerId + (i * idStep),
				total = 40 + ((i % 5) * 4),
			})
			tick = tick + spacing
		end

		return tick
	end

	-- Explainer: after the big burst has faded, sprinkle higher-id customers to pull the
	-- 10x10 window forward while staying in the customer domain.
	local function addSlideProbers(opts)
		opts = opts or {}
		local tick = opts.startTick or 0
		local startId = opts.startId or 50000
		local step = opts.step or 150
		local count = opts.count or 10
		local spacing = opts.spacing or 0.6

		for i = 0, count - 1 do
			local id = startId + (i * step)
			emit(tick + (i * spacing), "customers", {
				id = id,
				name = string.format("Cust %d", id),
			})
		end

		return tick + (count - 1) * spacing
	end

	-- Stage A: short, fully matched flow that stays inside the 10x10 view. Emits 16 records
	-- (8 customers + 8 orders).
	local afterPairs = addMatchedPairs(0)
	snapshots[#snapshots + 1] = { tick = afterPairs + 0.2, label = "small_start" }

	-- Stage B: accelerating span-stretch to trip auto-zoom to 100x100. Emits 25 orders spaced
	-- 3 ids apart; spacing eases from 0.5s down to 0.1s.
	local afterBurst = addLargeBurst({
		startTick = afterPairs + 1.2,
		startOrderId = 200,
		startCustomerId = 61,
		count = 90,
		idStep = 4,
		spacingStart = 0.2,
		spacingEnd = 0.0001,
	})
	snapshots[#snapshots + 1] = { tick = afterBurst, label = "large_burst" }

	-- Stage C: idle long enough for the burst to decay, then nudge the window forward with
	-- high-id customers. Emits 10 customers spaced in time.
	local afterCooldown = afterBurst + 3
	snapshots[#snapshots + 1] = { tick = afterCooldown, label = "cooled_small" }
	local afterSlide = addSlideProbers({
		startTick = afterCooldown + 0.5,
		startId = 50003,
		step = 153,
		count = 10,
		spacing = 0.6,
	})
	snapshots[#snapshots + 1] = { tick = afterSlide, label = "slide_buffer" }

	-- Stage D: tight mixed trickle that fits 10x10 regardless of offset.
	local afterFinalLull = afterSlide + 16
	local finalTick = afterFinalLull
	local finalEvents = {
		{ schema = "customers", payload = { id = 10, name = "Final A" } },
		{ schema = "orders", payload = { id = 501, customerId = 10, total = 10 } },
		{ schema = "orders", payload = { id = 502, customerId = 42, total = 12 } }, -- unmatched
		{ schema = "customers", payload = { id = 20, name = "Final B" } },
		{ schema = "orders", payload = { id = 601, customerId = 20, total = 14 } },
		{ schema = "customers", payload = { id = 35, name = "Final C" } },
		{ schema = "orders", payload = { id = 602, customerId = 35, total = 16 } },
		{ schema = "orders", payload = { id = 603, customerId = 62, total = 18 } }, -- unmatched
		{ schema = "customers", payload = { id = 48, name = "Final D" } },
		{ schema = "orders", payload = { id = 604, customerId = 48, total = 20 } },
		{ schema = "customers", payload = { id = 60, name = "Final E" } },
		{ schema = "orders", payload = { id = 605, customerId = 60, total = 22 } },
		{ schema = "orders", payload = { id = 606, customerId = 70, total = 24 } }, -- unmatched
		{ schema = "customers", payload = { id = 68, name = "Final F" } },
		{ schema = "orders", payload = { id = 607, customerId = 68, total = 26 } },
	}
	for i, evt in ipairs(finalEvents) do
		finalTick = afterFinalLull + (i - 1) * 0.9
		emit(finalTick, evt.schema, evt.payload)
	end

	local finishTick = finalTick + 2
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
WindowZoomDemo.loveDefaults = LoveDefaults.merge({
	label = "window zoom",
	ticksPerSecond = 2,
	visualsTTL = 5,
	adjustInterval = 0.5,
})

return WindowZoomDemo
