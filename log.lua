-- Simple logging helper with LOG_LEVEL override.
-- Levels: FATAL, ERROR, WARN, INFO, DEBUG, TRACE. Default: WARN.
local Log = {}

local LEVEL_ORDER = {
	fatal = 0,
	error = 1,
	warn = 2,
	info = 3,
	debug = 4,
	trace = 5,
}

local LEVEL_NAMES = {
	"fatal",
	"error",
	"warn",
	"info",
	"debug",
	"trace",
}

local DEFAULT_LEVEL = "warn"

local function normalizeLevel(name)
	if not name then
		return nil
	end
	local lower = string.lower(tostring(name))
	if LEVEL_ORDER[lower] then
		return lower
	end
	return nil
end

local function envLevel()
	local specified = normalizeLevel(os.getenv("LOG_LEVEL"))
	if specified then
		return specified
	end
	if os.getenv("DEBUG") == "1" then
		return "debug"
	end
	return DEFAULT_LEVEL
end

local currentLevel = envLevel()

local function emit(levelName, message)
	io.stderr:write(string.format("[%s] %s\n", string.upper(levelName), tostring(message)))
end

local function prefixTag(tag, fmt)
	if not tag or tag == "" then
		return fmt
	end
	return string.format("[%s] %s", tostring(tag), fmt)
end

function Log.getLevel()
	return currentLevel
end

function Log.setLevel(levelName)
	local normalized = normalizeLevel(levelName)
	if not normalized then
		return nil, string.format("invalid log level: %s", tostring(levelName))
	end
	currentLevel = normalized
	return true
end

function Log.levels()
	return LEVEL_NAMES
end

function Log.isEnabled(levelName)
	local normalized = normalizeLevel(levelName)
	if not normalized then
		return false
	end
	return LEVEL_ORDER[normalized] <= LEVEL_ORDER[currentLevel]
end

function Log.log(levelName, fmt, ...)
	local normalized = normalizeLevel(levelName)
	if not normalized then
		return
	end
	if not Log.isEnabled(normalized) then
		return
	end
	local message
	if select("#", ...) > 0 then
		message = string.format(fmt, ...)
	else
		message = tostring(fmt)
	end
	emit(normalized, message)
end

function Log.fatal(fmt, ...)
	Log.log("fatal", fmt, ...)
end

function Log.error(fmt, ...)
	Log.log("error", fmt, ...)
end

function Log.warn(fmt, ...)
	Log.log("warn", fmt, ...)
end

function Log.info(fmt, ...)
	Log.log("info", fmt, ...)
end

function Log.debug(fmt, ...)
	Log.log("debug", fmt, ...)
end

function Log.trace(fmt, ...)
	Log.log("trace", fmt, ...)
end

function Log.tagged(levelName, tag, fmt, ...)
	Log.log(levelName, prefixTag(tag, fmt), ...)
end

function Log.withTag(tag)
	local tagged = {}
	local prefix = tag and tostring(tag) or ""
	local function wrap(levelName)
		return function(_, fmt, ...)
			Log.log(levelName, prefixTag(prefix, fmt), ...)
		end
	end
	function tagged:log(levelName, fmt, ...)
		Log.log(levelName, prefixTag(prefix, fmt), ...)
	end
	tagged.fatal = wrap("fatal")
	tagged.error = wrap("error")
	tagged.warn = wrap("warn")
	tagged.info = wrap("info")
	tagged.debug = wrap("debug")
	tagged.trace = wrap("trace")
	return tagged
end

function Log.assert(condition, fmt, ...)
	if condition then
		return true
	end
	if fmt then
		Log.error(fmt, ...)
	else
		Log.error("assertion failed")
	end
	return false
end

return Log
