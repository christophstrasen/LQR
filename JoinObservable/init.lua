local rx = require("reactivex")
local io = require("io")

local JoinObservable = {}

local DEFAULT_MAX_CACHE_SIZE = 5

local function defaultWarningHandler(message)
	local sink = io and io.stderr
	if sink and sink.write then
		sink:write(("[JoinObservable] warning: %s\n"):format(message))
	elseif print then
		print(("[JoinObservable] warning: %s"):format(message))
	end
end

local warningHandler = defaultWarningHandler

local function warnf(message, ...)
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

local function normalizeKeySelector(on)
	if type(on) == "function" then
		return on
	end

	local field = on or "id"
	return function(entry)
		return entry[field]
	end
end

local function touchKey(order, key)
	for i = 1, #order do
		if order[i] == key then
			table.remove(order, i)
			break
		end
	end
	table.insert(order, key)
end

local function defaultMerge(leftObservable, rightObservable)
	return leftObservable:merge(rightObservable)
end

local function tagStream(stream, side)
	return stream:map(function(entry)
		return {
			side = side,
			entry = entry,
		}
	end)
end

local function emitPair(observer, leftEntry, rightEntry)
	observer:onNext({
		left = leftEntry,
		right = rightEntry,
	})
end

local function noop() end

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

local function resolveStrategy(joinType)
	local normalized = (joinType or "inner"):lower()
	local strategy = joinStrategies[normalized]
	if not strategy then
		error(("Unsupported joinType '%s'"):format(tostring(joinType)))
	end
	return strategy
end

local function emitUnmatched(observer, strategy, side, record)
	if not record or record.matched then
		return
	end

	if side == "left" and strategy.emitUnmatchedLeft then
		emitPair(observer, record.entry, nil)
	elseif side == "right" and strategy.emitUnmatchedRight then
		emitPair(observer, nil, record.entry)
	end
end

local function normalizeExpirationWindow(options)
	local config = options.expirationWindow or {}
	local mode = (config.mode or "count")
	mode = mode:lower()

	local function resolveMaxItems()
		local maxItems = config.maxItems or config.maxCacheSize or options.maxCacheSize or DEFAULT_MAX_CACHE_SIZE
		assert(type(maxItems) == "number" and maxItems >= 1, "expirationWindow.maxItems must be a positive number")
		return maxItems
	end

	if mode == "count" then
		return {
			mode = "count",
			maxItems = resolveMaxItems(),
		}
	elseif mode == "interval" then
		local field = config.field
		assert(field, "expirationWindow.field is required for interval mode")
		local maxAge = config.maxAgeMs or config.maxAge or config.ttl
		assert(type(maxAge) == "number" and maxAge >= 0, "expirationWindow.maxAgeMs must be a non-negative number")
		local currentFn = config.currentFn or os.time
		assert(type(currentFn) == "function", "expirationWindow.currentFn must be a function")
		return {
			mode = "interval",
			field = field,
			maxAge = maxAge,
			currentFn = currentFn,
			reason = config.reason or "expired_interval",
		}
	elseif mode == "predicate" then
		local predicate = config.predicate or config.evaluator
		assert(type(predicate) == "function", "expirationWindow.predicate must be a function")
		local currentFn = config.currentFn or os.time
		assert(type(currentFn) == "function", "expirationWindow.currentFn must be a function")
		return {
			mode = "predicate",
			predicate = predicate,
			currentFn = currentFn,
			reason = config.reason or "expired_predicate",
		}
	else
		error(("Unsupported expirationWindow mode '%s'"):format(tostring(config.mode)))
	end
end

local function createRetentionEnforcer(expirationConfig, publishExpirationFn, emitUnmatchedFn)
	if expirationConfig.mode == "count" then
		local maxItems = expirationConfig.maxItems
		return function(cache, order, side)
			while #order > maxItems do
				local oldestKey = table.remove(order, 1)
				local record = cache[oldestKey]
				cache[oldestKey] = nil
				publishExpirationFn(side, oldestKey, record, "evicted")
				emitUnmatchedFn(side, record)
			end
		end
	elseif expirationConfig.mode == "interval" then
		local field = expirationConfig.field
		local maxAge = expirationConfig.maxAge
		local currentFn = expirationConfig.currentFn
		local reason = expirationConfig.reason
		return function(cache, order, side)
			local now = currentFn()
			local index = 1
			while index <= #order do
				local key = order[index]
				local record = cache[key]
				if not record then
					table.remove(order, index)
				else
					local value = record.entry and record.entry[field]
					if type(value) ~= "number" then
						warnf("Cannot evaluate interval expiration for %s entry: field '%s' missing or not numeric", side, field)
						index = index + 1
					elseif now - value > maxAge then
						table.remove(order, index)
						cache[key] = nil
						publishExpirationFn(side, key, record, reason)
						emitUnmatchedFn(side, record)
					else
						index = index + 1
					end
				end
			end
		end
	elseif expirationConfig.mode == "predicate" then
		local predicate = expirationConfig.predicate
		local currentFn = expirationConfig.currentFn
		local reason = expirationConfig.reason
		return function(cache, order, side)
			local ctx = {
				now = currentFn,
			}
			local index = 1
			while index <= #order do
				local key = order[index]
				local record = cache[key]
				if not record then
					table.remove(order, index)
				else
					local keep = true
					local ok, result = pcall(predicate, record.entry, side, ctx)
					if not ok then
						warnf("expirationWindow predicate errored for %s entry: %s", side, tostring(result))
					else
						keep = not not result
					end

					if keep then
						index = index + 1
					else
						table.remove(order, index)
						cache[key] = nil
						publishExpirationFn(side, key, record, reason)
						emitUnmatchedFn(side, record)
					end
				end
			end
		end
	end
end

function JoinObservable.createJoinObservable(leftStream, rightStream, options)
	assert(leftStream, "leftStream is required")
	assert(rightStream, "rightStream is required")

	options = options or {}

	local strategy = resolveStrategy(options.joinType)
	local keySelector = normalizeKeySelector(options.on)
	local expirationConfig = normalizeExpirationWindow(options)
	local mergeSources = options.merge or defaultMerge

	local expiredSubject = rx.Subject.create()
	local expiredClosed = false

	local function closeExpiredWith(method, ...)
		if expiredClosed then
			return
		end
		expiredClosed = true
		expiredSubject[method](expiredSubject, ...)
	end

	local function publishExpiration(side, key, record, reason)
		if not record or record.matched then
			return
		end

		expiredSubject:onNext({
			side = side,
			key = key,
			entry = record.entry,
			reason = reason,
		})
	end

	local observable = rx.Observable.create(function(observer)
		local leftCache, rightCache = {}, {}
		local leftOrder, rightOrder = {}, {}
		local enforceRetention = createRetentionEnforcer(expirationConfig, publishExpiration, function(side, record)
			emitUnmatched(observer, strategy, side, record)
		end)

		local function handleMatch(leftRecord, rightRecord)
			leftRecord.matched = true
			rightRecord.matched = true
			strategy.onMatch(observer, leftRecord, rightRecord)
		end

		local function handleEntry(side, cache, otherCache, order, entry)
			local key = keySelector(entry)
			if key == nil then
				warnf("Dropped %s entry because join key resolved to nil", side)
				return
			end

			local record = cache[key]
			if record then
				record.entry = entry
				record.matched = false
				record.key = key
			else
				cache[key] = {
					entry = entry,
					matched = false,
					key = key,
				}
				record = cache[key]
			end

			touchKey(order, key)

			local other = otherCache[key]
			if other then
				if side == "left" then
					handleMatch(record, other)
				else
					handleMatch(other, record)
				end
			end

			enforceRetention(cache, order, side)
		end

		local function flushCache(cache, side, reason)
			for key, record in pairs(cache) do
				cache[key] = nil
				publishExpiration(side, key, record, reason)
				emitUnmatched(observer, strategy, side, record)
			end
		end

		local leftTagged = tagStream(leftStream, "left")
		local rightTagged = tagStream(rightStream, "right")
		local merged = mergeSources(leftTagged, rightTagged)
		assert(merged and merged.subscribe, "mergeSources must return an observable")

		local subscription
		subscription = merged:subscribe(function(packet)
			if type(packet) ~= "table" then
				warnf("Ignoring packet emitted as %s (expected table)", type(packet))
				return
			end

			local side = packet.side
			local entry = packet.entry

			if side == "left" then
				handleEntry("left", leftCache, rightCache, leftOrder, entry)
			elseif side == "right" then
				handleEntry("right", rightCache, leftCache, rightOrder, entry)
			end
		end, function(err)
			observer:onError(err)
			closeExpiredWith("onError", err)
		end, function()
			flushCache(leftCache, "left", "completed")
			flushCache(rightCache, "right", "completed")
			observer:onCompleted()
			closeExpiredWith("onCompleted")
		end)

		return function()
			if subscription then
				subscription:unsubscribe()
			end
			closeExpiredWith("onCompleted")
		end
	end)

	return observable, expiredSubject
end

function JoinObservable.setWarningHandler(handler)
	if handler ~= nil and type(handler) ~= "function" then
		error("setWarningHandler expects a function or nil")
	end

	local previous = warningHandler
	warningHandler = handler or defaultWarningHandler
	return previous
end

return JoinObservable
