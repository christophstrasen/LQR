local rx = require("reactivex")
local Strategies = require("JoinObservable.strategies")
local Expiration = require("JoinObservable.expiration")
local warnings = require("JoinObservable.warnings")

local warnf = warnings.warnf

local JoinObservable = {}

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

local function emitUnmatched(observer, strategy, side, record)
	if not record or record.matched then
		return
	end

	if side == "left" and strategy.emitUnmatchedLeft then
		observer:onNext({
			left = record.entry,
			right = nil,
		})
	elseif side == "right" and strategy.emitUnmatchedRight then
		observer:onNext({
			left = nil,
			right = record.entry,
		})
	end
end

function JoinObservable.createJoinObservable(leftStream, rightStream, options)
	assert(leftStream, "leftStream is required")
	assert(rightStream, "rightStream is required")

	options = options or {}

	local strategy = Strategies.resolve(options.joinType)
	local keySelector = normalizeKeySelector(options.on)
	local expirationConfig = Expiration.normalize(options)
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
		local enforceRetention = Expiration.createEnforcer(expirationConfig, publishExpiration, function(side, record)
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
	return warnings.setWarningHandler(handler)
end

return JoinObservable
