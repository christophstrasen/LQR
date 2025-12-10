-- Join strategy table describing how to emit matches/unmatched rows for each join type.
local Result = require("LQR.JoinObservable.result")

local Strategies = {}

local function emitResult(observer, leftRecord, rightRecord)
	local record = Result.new()
	if leftRecord then
		record:attach(leftRecord.schemaName, leftRecord.entry)
	end
	if rightRecord then
		record:attach(rightRecord.schemaName, rightRecord.entry)
	end
	observer:onNext(record)
end

local function noop() end

local joinStrategies = {
	inner = {
		onMatch = function(observer, leftRecord, rightRecord)
			emitResult(observer, leftRecord, rightRecord)
		end,
		emitUnmatchedLeft = false,
		emitUnmatchedRight = false,
	},
	left = {
		onMatch = function(observer, leftRecord, rightRecord)
			emitResult(observer, leftRecord, rightRecord)
		end,
		emitUnmatchedLeft = true,
		emitUnmatchedRight = false,
	},
	right = {
		onMatch = function(observer, leftRecord, rightRecord)
			emitResult(observer, leftRecord, rightRecord)
		end,
		emitUnmatchedLeft = false,
		emitUnmatchedRight = true,
	},
	outer = {
		onMatch = function(observer, leftRecord, rightRecord)
			emitResult(observer, leftRecord, rightRecord)
		end,
		emitUnmatchedLeft = true,
		emitUnmatchedRight = true,
	},
	anti_left = {
		onMatch = noop,
		emitUnmatchedLeft = true,
		emitUnmatchedRight = false,
	},
	anti_right = {
		onMatch = noop,
		emitUnmatchedLeft = false,
		emitUnmatchedRight = true,
	},
	anti_outer = {
		onMatch = noop,
		emitUnmatchedLeft = true,
		emitUnmatchedRight = true,
	},
}

function Strategies.resolve(joinType)
	local normalized = (joinType or "inner"):lower()
	local strategy = joinStrategies[normalized]
	if not strategy then
		error(("Unsupported joinType '%s'"):format(tostring(joinType)))
	end
	return strategy
end

return Strategies
