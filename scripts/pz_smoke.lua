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
	local old_os = os

	local ok, err = pcall(function()
		setup()
		run_modules()
	end)

	-- Restore globals so later probes behave normally.
	_G.debug = old_debug
	package = old_package
	os = old_os

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

-- Probe 1b: next missing (simulate runtimes where next is nil).
all_ok = probe("next-nil", function()
	_G.debug = nil
	_G.next = nil
end) and all_ok

-- Probe 1c: os.getenv missing (matches PZ Kahlua).
all_ok = probe("os-getenv-nil", function()
	_G.debug = nil
	if type(os) ~= "table" then
		os = {}
	end
	os.getenv = nil
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

-- Probe 3: package missing entirely (simulate stricter host).
all_ok = probe("package-nil", function()
	_G.debug = nil
	package = nil
end) and all_ok

-- Probe 4: os missing (simulate runtimes without os.*).
all_ok = probe("os-nil", function()
	_G.debug = nil
	package = nil
	os = nil
end) and all_ok

local function safe_exit(code)
	if os and os.exit then
		os.exit(code)
	end
	return code
end

if not all_ok then
	safe_exit(1)
end
