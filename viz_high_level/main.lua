package.path = table.concat({
	package.path,
	"./?.lua",
	"./?/init.lua",
	"../?.lua",
	"../?/init.lua",
}, ";")

require("bootstrap")

local LoveRunner = require("viz_high_level.demo.love_runner")

local function addIfHasInit(root, entry, dest)
	local initPath = string.format("%s/%s/init.lua", root, entry)
	local fh = io.open(initPath, "r")
	if fh then
		fh:close()
		dest[#dest + 1] = entry
	end
end

local function listDemoFolders()
	local root = "viz_high_level/demo"
	local found = {}

	local ok, lfs = pcall(require, "lfs")
	if ok and lfs then
		for entry in lfs.dir(root) do
			if entry ~= "." and entry ~= ".." then
				local path = root .. "/" .. entry
				local attr = lfs.attributes(path)
				if attr and attr.mode == "directory" then
					addIfHasInit(root, entry, found)
				end
			end
		end
		if #found > 0 then
			return found
		end
	end

	local handle = io.popen(string.format("ls -1 %s 2>/dev/null", root))
	if handle then
		for entry in handle:lines() do
			addIfHasInit(root, entry, found)
		end
		handle:close()
		if #found > 0 then
			return found
		end
	end

	-- Fallback to known demos if discovery fails.
	local known = { "timeline", "simple", "window_zoom", "two_zones" }
	for _, name in ipairs(known) do
		addIfHasInit(root, name, found)
	end

	return found
end
local function buildAllowedSet(list)
	local set = {}
	for _, name in ipairs(list or {}) do
		set[string.lower(name)] = true
	end
	return set
end

local AVAILABLE_DEMOS = listDemoFolders()
local ALLOWED = buildAllowedSet(AVAILABLE_DEMOS)

local function normalizeChoice(raw)
	if not raw then
		return nil
	end
	raw = string.lower(tostring(raw))
	if ALLOWED[raw] then
		return raw
	end
	return nil
end

local function detectChoice()
	local args = rawget(_G, "arg")
	if args then
		for i = 1, #args do
			local choice = normalizeChoice(args[i])
			if choice then
				return choice
			end
		end
	end
	return "timeline"
end

local choice = detectChoice()

local scenarioModule = string.format("viz_high_level.demo.%s", choice)

LoveRunner.bootstrap({
	scenarioModule = scenarioModule,
})
