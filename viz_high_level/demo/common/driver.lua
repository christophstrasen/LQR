local Driver = {}

local Scheduler = require("viz_high_level.demo.scheduler")

---Create a standard demo driver around Scheduler.
---@param args table
---@return table driver
function Driver.new(args)
	local events = assert(args.events, "driver requires events")
	local subjects = assert(args.subjects, "driver requires subjects")
	local label = args.label or "demo"
	local ticksPerSecond = args.ticksPerSecond or 2
	local clock = args.clock
	local completeAll = args.onCompleteAll

	local scheduler
	local function stampTick(event)
		if clock and clock.set then
			local tick = event.tick or (scheduler and scheduler:currentTick()) or 0
			clock:set(tick)
		end
	end

	scheduler = Scheduler.new({
		events = events,
		handlers = {
			emit = function(event)
				stampTick(event)
				local subject = subjects[event.schema]
				assert(subject, string.format("Unknown schema %s in %s demo", tostring(event.schema), label))
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
				if completeAll then
					completeAll(subjects)
				else
					for _, subject in pairs(subjects or {}) do
						if subject.onCompleted then
							subject:onCompleted()
						end
					end
				end
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
		if completeAll then
			completeAll(subjects)
		else
			for _, subject in pairs(subjects or {}) do
				if subject.onCompleted then
					subject:onCompleted()
				end
			end
		end
		driver.finished = true
	end

	function driver:update(dt)
		if driver.finished then
			return
		end
		local deltaTicks = math.max(0, (dt or 0) * ticksPerSecond)
		if clock and clock.set and clock.now then
			clock:set(clock:now() + deltaTicks)
		end
		scheduler:advance(deltaTicks)
		if scheduler:isFinished() then
			finalize()
		end
	end

	function driver:runUntil(targetTick)
		if driver.finished then
			return
		end
		if clock and clock.set then
			clock:set(targetTick)
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
		if clock and clock.set and scheduler and scheduler:currentTick() then
			clock:set(scheduler:currentTick())
		end
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

return Driver
