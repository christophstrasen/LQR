local Observable = require("reactivex.observable")
local Subject = require("reactivex.subjects.subject")
local Subscription = require("reactivex.subscription")
local CooperativeScheduler = require("reactivex.schedulers.cooperativescheduler")

-- Ensure all standard operators (map, concat, etc.) are registered on Observable.
require("reactivex.operators")

local rx = setmetatable({}, { __index = Observable })

rx.Observable = Observable
rx.Subject = Subject
rx.Subscription = Subscription
rx.CooperativeScheduler = CooperativeScheduler

local defaultScheduler

local function ensureScheduler(currentTime)
	if not defaultScheduler then
		defaultScheduler = CooperativeScheduler.create(currentTime)
	end
	return defaultScheduler
end

local schedulerHelpers = {}

function schedulerHelpers.use(scheduler)
	defaultScheduler = scheduler
	return defaultScheduler
end

function schedulerHelpers.get()
	return ensureScheduler()
end

function schedulerHelpers.reset(currentTime)
	defaultScheduler = CooperativeScheduler.create(currentTime)
	return defaultScheduler
end

function schedulerHelpers.schedule(action, delay)
	return ensureScheduler():schedule(action, delay)
end

function schedulerHelpers.update(delta)
	ensureScheduler():update(delta)
end

function schedulerHelpers.start(step, maxIterations)
	local scheduler = ensureScheduler()
	step = step or 1
	local iterations = 0
	while not scheduler:isEmpty() do
		scheduler:update(step)
		iterations = iterations + 1
		if maxIterations and iterations >= maxIterations then
			break
		end
	end
	return scheduler
end

rx.scheduler = schedulerHelpers

return rx
