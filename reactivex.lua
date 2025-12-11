-- Flattened entrypoint so hosts can require("reactivex") without init.lua lookup.
-- Prefer sibling lua-reactivex checkout when present; otherwise fall back to package.path.
local base_dir = "./"
do
	local info = debug and debug.getinfo and debug.getinfo(1, "S")
	local source = info and info.source or ""
	if source:sub(1, 1) == "@" then
		source = source:sub(2)
	end
	local dir = source:match("(.*/)") or "./"
	base_dir = dir
end

local module
do
	-- Try sibling checkout directly (works even if searchers/path are locked down).
	local chunk = loadfile(base_dir .. "../lua-reactivex/reactivex.lua")
		or loadfile(base_dir .. "../lua-reactivex/reactivex/reactivex.lua")
	if chunk then
		module = chunk()
	else
		local ok, result = pcall(require, "reactivex/reactivex")
		if not ok then
			error(string.format("reactivex: failed to load core module: %s", tostring(result)))
		end
		module = result
	end
end

-- Preload operators aggregator if available to satisfy require("reactivex/operators") without init.lua recursion.
do
	local op_chunk = loadfile("./operators.lua") or loadfile("../lua-reactivex/operators.lua") or loadfile(base_dir .. "../lua-reactivex/operators.lua")
	if op_chunk then
		local function loader()
			package.loaded["reactivex/operators"] = true
			package.loaded["reactivex.operators"] = true
			return op_chunk()
		end
		package.preload["reactivex/operators"] = loader
		package.preload["reactivex.operators"] = loader
	end
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
