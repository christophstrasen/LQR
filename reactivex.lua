-- Flattened entrypoint matching the vendored submodule so hosts can require("reactivex") without init.lua lookup.
local info = debug.getinfo(1, "S")
local source = info and info.source or ""
if source:sub(1, 1) == "@" then
	source = source:sub(2)
end
local base_dir = source:match("(.*/)") or "./"
local function join(dir, suffix)
	if dir:sub(-1) == "/" then
		return dir .. suffix
	end
	return dir .. "/" .. suffix
end

local candidates = {
	join(base_dir, "reactivex/reactivex.lua"),
	join(base_dir, "reactivex/init.lua"),
	join(base_dir, "reactivex/reactivex/init.lua"),
}

local chunk, err
for _, path in ipairs(candidates) do
	chunk, err = loadfile(path)
	if chunk then
		break
	end
end

if not chunk then
	error(err)
end
local module = chunk()

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
