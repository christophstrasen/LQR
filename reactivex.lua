-- Flattened entrypoint matching reactivex/init.lua so hosts can require("reactivex") without init.lua lookup.
local util = require("reactivex.util")
local Subscription = require("reactivex.subscription")
local Observer = require("reactivex.observer")
local Observable = require("reactivex.observable")
local ImmediateScheduler = require("reactivex.schedulers.immediatescheduler")
local CooperativeScheduler = require("reactivex.schedulers.cooperativescheduler")
local TimeoutScheduler = require("reactivex.schedulers.timeoutscheduler")
local Subject = require("reactivex.subjects.subject")
local AsyncSubject = require("reactivex.subjects.asyncsubject")
local BehaviorSubject = require("reactivex.subjects.behaviorsubject")
local ReplaySubject = require("reactivex.subjects.replaysubject")

require("reactivex.operators.init")
require("reactivex.aliases")

local rx = {
	util = util,
	Subscription = Subscription,
	Observer = Observer,
	Observable = Observable,
	ImmediateScheduler = ImmediateScheduler,
	CooperativeScheduler = CooperativeScheduler,
	TimeoutScheduler = TimeoutScheduler,
	Subject = Subject,
	AsyncSubject = AsyncSubject,
	BehaviorSubject = BehaviorSubject,
	ReplaySubject = ReplaySubject,
}

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
