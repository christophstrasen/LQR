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
local LOGGER_TAG = "LOGGER"

local function safe_getenv(name)
	if type(os) == "table" and type(os.getenv) == "function" then
		return os.getenv(name)
	end
	return nil
end

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
	local specified = normalizeLevel(safe_getenv("LOG_LEVEL"))
	if specified then
		return specified
	end
	if safe_getenv("DEBUG") == "1" then
		return "debug"
	end
	return DEFAULT_LEVEL
end

local function sanitizeMessage(message)
	local msg = tostring(message or "")
	-- Avoid colons that can be mangled by PZ log rendering; surface them clearly.
	return msg:gsub(":", "DOUBLECOLON")
end

local function emitLine(line)
	local sanitized = sanitizeMessage(line)
	if io and io.stderr and io.stderr.write then
		io.stderr:write(sanitized .. "\n")
	else
		-- Fall back to print in restricted runtimes (e.g. PZ Kahlua).
		print(sanitized)
	end
end

local defaultEmitter = function(levelName, message, tag)
	local msg = sanitizeMessage(message)
	-- Emit a one-off trace if we ever log a nil/\"nil\" message for a specific tag to help locate sources.
	if tag == "viz-hi" and msg == "nil" and debug and debug.traceback then
		emitLine(string.format("[WARN][LOGGER] nil log message for tag=%s", tostring(tag)))
		emitLine(debug.traceback("", 3))
	end
	if tag and tag ~= "" then
		emitLine(string.format("[%s][%s] %s", string.upper(levelName), tag, msg))
	else
		emitLine(string.format("[%s] %s", string.upper(levelName), msg))
	end
end

local emitter = defaultEmitter
local currentLevel = envLevel()
local tagInclude
local tagExclude

local function prefixTag(tag, fmt)
	if not tag or tag == "" then
		return fmt
	end
	return string.format("[%s] %s", tostring(tag), fmt)
end

local function emit(levelName, message, tag)
	if emitter then
		emitter(levelName, message, tag)
	end
end

local function splitTags(raw)
	if not raw or raw == "" then
		return nil
	end
	local set = {}
	for token in string.gmatch(raw, "([^,]+)") do
		local trimmed = token:gsub("^%s+", ""):gsub("%s+$", "")
		if trimmed ~= "" then
			set[trimmed] = true
		end
	end
	for _ in pairs(set) do
		return set
	end
	return nil
end

	tagInclude = splitTags(safe_getenv("LOG_TAG_INCLUDE"))
	tagExclude = splitTags(safe_getenv("LOG_TAG_EXCLUDE"))

if tagInclude and tagExclude then
	defaultEmitter("warn", "LOG_TAG_INCLUDE and LOG_TAG_EXCLUDE both set; ignoring tag filters", LOGGER_TAG)
	tagInclude, tagExclude = nil, nil
end

local function tagAllowed(tag)
	if tagInclude then
		return tag and tagInclude[tag] == true
	end
	if tagExclude and tag and tagExclude[tag] then
		return false
	end
	return true
end

function Log.getLevel()
	return currentLevel
end

function Log.setLevel(levelName)
	local normalized = normalizeLevel(levelName)
	if not normalized then
	return nil, string.format("invalid log level - %s", tostring(levelName))
	end
	currentLevel = normalized
	return true
end

function Log.levels()
	return LEVEL_NAMES
end

function Log.isEnabled(levelName, tag)
	local normalized = normalizeLevel(levelName)
	if not normalized then
		return false
	end
	if not tagAllowed(tag) then
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
	if fmt == nil and select("#", ...) == 0 then
		return
	end
	local message
	if select("#", ...) > 0 then
		message = string.format(fmt, ...)
	else
		message = tostring(fmt)
	end
	if message == nil then
		return
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
	local normalized = normalizeLevel(levelName)
	if not normalized or not Log.isEnabled(normalized, tag) then
		return
	end
	local message
	if select("#", ...) > 0 then
		message = string.format(fmt, ...)
	else
		message = tostring(fmt)
	end
	emit(normalized, message, tag)
end

function Log.withTag(tag)
	local tagged = {}
	local prefix = tag and tostring(tag) or ""
	local function wrap(levelName)
		return function(_, fmt, ...)
			local normalized = normalizeLevel(levelName)
			if not normalized or not Log.isEnabled(normalized, prefix) then
				return
			end
			-- Avoid logging nil fmt; tag-aware callers should pass a format string.
			local message
			if select("#", ...) > 0 then
				message = string.format(fmt, ...)
			else
				message = tostring(fmt)
			end
			emit(normalized, message, prefix)
		end
	end
	function tagged:log(levelName, fmt, ...)
		local normalized = normalizeLevel(levelName)
		if not normalized or not Log.isEnabled(normalized, prefix) then
			return
		end
		local message
		if select("#", ...) > 0 then
			message = string.format(fmt, ...)
		else
			message = tostring(fmt)
		end
		emit(normalized, message, prefix)
	end
	tagged.fatal = wrap("fatal")
	tagged.error = wrap("error")
	tagged.warn = wrap("warn")
	tagged.info = wrap("info")
	tagged.debug = wrap("debug")
	tagged.trace = wrap("trace")
	tagged.tag = prefix
	return tagged
end

---Temporarily suppress logs below a level while running fn, restoring the previous level afterwards.
---@param levelName string
---@param fn fun()
function Log.supressBelow(levelName, fn)
	local normalized = normalizeLevel(levelName)
	if not normalized then
		error(string.format("invalid log level - %s", tostring(levelName)))
	end
	assert(type(fn) == "function", "supressBelow expects a function")
	local previous = currentLevel
	currentLevel = normalized
	local ok, err = pcall(fn)
	currentLevel = previous
	if not ok then
		error(err)
	end
end

function Log.setEmitter(handler)
	if handler ~= nil and type(handler) ~= "function" then
		error("setEmitter expects a function or nil")
	end
	local previous = emitter
	emitter = handler or defaultEmitter
	return previous
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
