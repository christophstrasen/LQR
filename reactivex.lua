-- Flattened entrypoint so hosts can require("reactivex") without init.lua lookup or debug/loadfile.
local ok, module = pcall(require, "reactivex/reactivex")
if not ok then
	error(string.format("reactivex: failed to load core module: %s", tostring(module)))
end

-- Provide a scheduler helper that mirrors our CLI expectations without touching
-- the vendored code. This keeps tests (and consumers) working even if the
-- upstream module doesn't expose a scheduler table.
if not module.scheduler then
	local CooperativeScheduler = module.CooperativeScheduler
		or module.CooperativeScheduler
		or module.Cooperative
		or (module.schedulers and module.schedulers.cooperativescheduler)
		or require("reactivex/schedulers/cooperativescheduler")

	local defaultScheduler
	local function ensureScheduler(currentTime)
		if not defaultScheduler then
			defaultScheduler = CooperativeScheduler.create(currentTime)
		end
		return defaultScheduler
	end

	module.scheduler = {
		use = function(scheduler)
			defaultScheduler = scheduler
			return defaultScheduler
		end,
		get = function()
			return ensureScheduler()
		end,
		reset = function(currentTime)
			defaultScheduler = CooperativeScheduler.create(currentTime)
			return defaultScheduler
		end,
		schedule = function(action, delay)
			return ensureScheduler():schedule(action, delay)
		end,
		update = function(delta)
			ensureScheduler():update(delta)
		end,
		start = function(step, maxIterations)
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
		end,
	}
end

package.loaded["reactivex"] = module
return module
