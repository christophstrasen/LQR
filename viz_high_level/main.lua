package.path = table.concat({
	package.path,
	"./?.lua",
	"./?/init.lua",
	"../?.lua",
	"../?/init.lua",
}, ";")

require("bootstrap")

local LoveRunner = require("viz_high_level.demo.love_runner")

local function normalizeChoice(raw)
	if not raw then
		return nil
	end
	raw = string.lower(tostring(raw))
	if raw == "simple" or raw == "timeline" or raw == "window_zoom" then
		return raw
	end
	return nil
end

local function parseArgChoice(args)
	if not args then
		return nil
	end
	local afterSeparator = false
	for i = 1, #args do
		local value = args[i]
		if value == "--" then
			afterSeparator = true
		elseif value == "--demo" then
			return normalizeChoice(args[i + 1])
		elseif value and value:match("^%-%-demo=") then
			local choice = value:match("^%-%-demo=(.+)")
			return normalizeChoice(choice)
		elseif afterSeparator or (value and not value:match("^%-%-")) then
			local choice = normalizeChoice(value)
			if choice then
				return choice
			end
		end
	end
	return nil
end

local function detectChoice()
	local envChoice = normalizeChoice(os.getenv("VIZ_VIZ_DEMO") or os.getenv("VIZ_DEMO"))
	if envChoice then
		return envChoice
	end
	return parseArgChoice(rawget(_G, "arg")) or "timeline"
end

local choice = detectChoice()

local scenarioModule
if choice == "simple" then
	scenarioModule = "viz_high_level.demo.simple"
elseif choice == "window_zoom" then
	scenarioModule = "viz_high_level.demo.window_zoom"
else
	scenarioModule = "viz_high_level.demo.timeline"
end

LoveRunner.bootstrap({
	scenarioModule = scenarioModule,
})
