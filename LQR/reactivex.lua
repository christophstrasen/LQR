require("LQR/bootstrap")

local function requireReactiveX(module)
	local ok, result = pcall(require, module)
	if not ok then
		error(
			string.format(
				"lua-reactivex dependency missing: %s. Check out https://github.com/christophstrasen/lua-reactivex/tree/main/reactivex into ./reactivex before running LQR. For Project Zomboid users ensure you load all required mod dependencies. Original error: %s",
				module,
				result
			)
		)
	end
	return result
end

-- Explainer: Root entrypoint that mirrors 4O4/lua-reactivex but force-loads operators and
-- collects helpers so other modules can `require("reactivex")` without wiring schedulers.
local Observable = requireReactiveX("reactivex/observable")
local Subject = requireReactiveX("reactivex/subjects/subject")
local Subscription = requireReactiveX("reactivex/subscription")
local CooperativeScheduler = requireReactiveX("reactivex/schedulers/cooperativescheduler")

-- Ensure all standard operators (map, concat, etc.) are registered on Observable.
requireReactiveX("reactivex/operators")

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

-- Explainer: Tests/demos frequently reset time to deterministic baselines; this keeps the
-- shared scheduler controllable instead of pulling from a global singleton.
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
