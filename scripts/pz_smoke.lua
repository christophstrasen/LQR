-- PZ-style loader smoke test for the workshop build.
-- Run this after syncing to the destination tree to catch missing debug/package
-- or path issues before launching the game.

local function join(...)
	return table.concat({ ... }, ";")
end

-- Default to the synced workshop tree. Override with PZ_LUA_PATH to point
-- elsewhere if needed.
local default_path = join(
	"./Contents/mods/WorldObserver/42/media/lua/shared/?.lua",
	"./Contents/mods/WorldObserver/42/media/lua/shared/?/init.lua",
	"?.lua",
	"?.lua",
	";;"
)

local lua_path = os.getenv("PZ_LUA_PATH") or default_path
if package and package.path then
	package.path = lua_path
end

local modules = {}
if #arg > 0 then
	for i = 1, #arg do
		table.insert(modules, arg[i])
	end
else
	modules = { "WorldObserver", "LQR", "reactivex" }
end

local function run_modules()
	for _, m in ipairs(modules) do
		local ok, err = pcall(require, m)
		if not ok then
			error(("require('%s') failed: %s"):format(m, err), 0)
		end
	end
end

local function probe(label, setup)
	local old_debug = _G.debug
	local old_package = package

	local ok, err = pcall(function()
		setup()
		run_modules()
	end)

	_G.debug = old_debug
	package = old_package

	if ok then
		io.stdout:write(("[pass] %s\n"):format(label))
		return true
	else
		io.stderr:write(("[fail] %s: %s\n"):format(label, tostring(err)))
		return false
	end
end

local all_ok = true

-- Probe 1: debug missing (as in PZ runtime).
all_ok = probe("no-debug", function()
	_G.debug = nil
end) and all_ok

-- Probe 2: package present but minimal (guards package.loaded accesses).
all_ok = probe("package-minimal", function()
	_G.debug = nil
	local original = package or {}
	package = {
		path = original.path,
		cpath = original.cpath,
		config = original.config,
		searchers = original.searchers or original.loaders,
		preload = original.preload,
		loaded = {},
	}
end) and all_ok

if not all_ok then
	os.exit(1)
end
