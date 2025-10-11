-- Thin wrapper that funnels JoinObservable warnings through an overrideable handler.
local io = require("io")

local Warnings = {}

local function defaultWarningHandler(message)
	local sink = io and io.stderr
	if sink and sink.write then
		sink:write(("[JoinObservable] warning: %s\n"):format(message))
	elseif print then
		print(("[JoinObservable] warning: %s"):format(message))
	end
end

local warningHandler = defaultWarningHandler

function Warnings.warnf(message, ...)
	if not warningHandler then
		return
	end

	local formatted
	if select("#", ...) > 0 then
		local ok, result = pcall(string.format, message, ...)
		formatted = ok and result or message
	else
		formatted = message
	end

	warningHandler(formatted)
end

function Warnings.setWarningHandler(handler)
	if handler ~= nil and type(handler) ~= "function" then
		error("setWarningHandler expects a function or nil")
	end

	local previous = warningHandler
	warningHandler = handler or defaultWarningHandler
	return previous
end

Warnings.defaultWarningHandler = defaultWarningHandler

return Warnings
