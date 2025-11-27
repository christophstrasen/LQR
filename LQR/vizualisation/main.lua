local info = debug.getinfo(1, "S")
local source = info and info.source or ""
if source:sub(1, 1) == "@" then
	source = source:sub(2)
end
local base_dir = source:match("(.*/)") or "./"
-- Fallback for Love launching from a game root without path info.
if (not base_dir or base_dir == "./") and love and love.filesystem and love.filesystem.getSourceBaseDirectory then
	local base = love.filesystem.getSourceBaseDirectory()
	if base and base ~= "" then
		base_dir = base
		if base_dir:sub(-1) ~= "/" then
			base_dir = base_dir .. "/"
		end
	end
end
local function join(dir, suffix)
	if dir:sub(-1) == "/" then
		return dir .. suffix
	end
	return dir .. "/" .. suffix
end

-- Ensure the LQR root and viz paths are on package.path regardless of CWD or love invocation.
package.path = table.concat({
	join(base_dir, "?.lua"),
	join(base_dir, "?/init.lua"),
	join(base_dir, "../?.lua"),
	join(base_dir, "../?/init.lua"),
	package.path,
}, ";")

require("LQR.bootstrap")

local LoveRunner = require("LQR.vizualisation.demo.love_runner")

local function addIfHasInit(root, entry, dest)
	local initPath = string.format("%s/%s/init.lua", root, entry)
	local fh = io.open(initPath, "r")
	if fh then
		fh:close()
		dest[#dest + 1] = entry
	end
end

local function listDemoFolders()
	local root = join(base_dir, "demo")
	local found = {}
	local known = {
		"timeline",
		"simple",
		"window_zoom",
		"two_zones",
		"two_circles",
		"three_circles",
		"three_circles_group",
		"single_group",
		"reingest_group",
	}

	if love and love.filesystem and love.filesystem.getDirectoryItems then
		local ok, entries = pcall(love.filesystem.getDirectoryItems, "demo")
		if ok and entries then
			for _, entry in ipairs(entries) do
				addIfHasInit("demo", entry, found)
			end
		end
	end
	if #found > 0 then
		return found
	end

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
			local raw = args[i]
			-- Ignore path-like args (e.g., launch dir) when choosing the demo.
			if type(raw) == "string" and not raw:find("/") and not raw:find("\\") then
				-- Use the first non-path arg even if discovery missed it.
				return string.lower(raw)
			end
		end
	end
	return AVAILABLE_DEMOS[1] or "timeline"
end

local choice = detectChoice()

local scenarioModule = string.format("LQR.vizualisation.demo.%s", choice)

LoveRunner.bootstrap({
	scenarioModule = scenarioModule,
})
