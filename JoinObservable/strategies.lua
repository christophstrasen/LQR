local Strategies = {}

local function emitPair(observer, leftEntry, rightEntry)
	observer:onNext({
		left = leftEntry,
		right = rightEntry,
	})
end

local function noop()
end

local joinStrategies = {
	inner = {
		onMatch = function(observer, leftRecord, rightRecord)
			emitPair(observer, leftRecord.entry, rightRecord.entry)
		end,
		emitUnmatchedLeft = false,
		emitUnmatchedRight = false,
	},
	left = {
		onMatch = function(observer, leftRecord, rightRecord)
			emitPair(observer, leftRecord.entry, rightRecord.entry)
		end,
		emitUnmatchedLeft = true,
		emitUnmatchedRight = false,
	},
	right = {
		onMatch = function(observer, leftRecord, rightRecord)
			emitPair(observer, leftRecord.entry, rightRecord.entry)
		end,
		emitUnmatchedLeft = false,
		emitUnmatchedRight = true,
	},
	outer = {
		onMatch = function(observer, leftRecord, rightRecord)
			emitPair(observer, leftRecord.entry, rightRecord.entry)
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

Strategies.emitPair = emitPair

return Strategies
