-- Core join implementation that pairs two schema-tagged streams and emits joined results.
local rx = require("reactivex")
local Schema = require("JoinObservable.schema")
local Result = require("JoinObservable.result")
local Strategies = require("JoinObservable.strategies")
local Expiration = require("JoinObservable.expiration")
local warnings = require("JoinObservable.warnings")

local warnf = warnings.warnf

local JoinObservable = {}

local function toFieldSelector(field, context)
	if type(field) ~= "string" or field == "" then
		error(("%s.field must be a non-empty string"):format(context))
	end
	return function(entry)
		return entry[field]
	end
end

local function buildSelector(entry, context)
	if entry == nil then
		return nil
	end

	local entryType = type(entry)
	if entryType == "string" then
		return toFieldSelector(entry, context)
	elseif entryType == "function" then
		return entry
	elseif entryType == "table" then
		if entry.field ~= nil then
			return toFieldSelector(entry.field, context)
		elseif type(entry.selector) == "function" then
			return entry.selector
		end
		error(("%s expects either 'field' (string) or 'selector' (function)"):format(context))
	else
		error(("%s must be a string, function, or table"):format(context))
	end
end

local function normalizeKeySelector(on)
	if type(on) == "function" then
		return on
	end

	if type(on) == "table" then
		local selectorsBySchema = {}
		local selectorCount = 0

		for schemaName, selectorConfig in pairs(on) do
			assert(type(schemaName) == "string" and schemaName ~= "", "options.on keys must be non-empty schema names")
			selectorsBySchema[schemaName] = buildSelector(selectorConfig, ("options.on['%s']"):format(schemaName))
			selectorCount = selectorCount + 1
		end

		assert(selectorCount > 0, "options.on must declare at least one schema selector")

		return function(entry, _side, schemaName)
			local selector = schemaName and selectorsBySchema[schemaName]
			if not selector then
				error(("No key selector configured for schema '%s'"):format(tostring(schemaName or "unknown")))
			end
			return selector(entry)
		end
	end

	local field = on or "id"
	return function(entry)
		return entry[field]
	end
end

local function defaultMerge(leftObservable, rightObservable)
	return rx.Observable.create(function(observer)
		local leftCompleted, rightCompleted = false, false
		local leftSub, rightSub

		local function tryComplete()
			if leftCompleted and rightCompleted then
				observer:onCompleted()
			end
		end

		leftSub = leftObservable:subscribe(function(value)
			observer:onNext(value)
		end, function(err)
			observer:onError(err)
			if rightSub then
				rightSub:unsubscribe()
			end
		end, function()
			leftCompleted = true
			tryComplete()
		end)

		rightSub = rightObservable:subscribe(function(value)
			observer:onNext(value)
		end, function(err)
			observer:onError(err)
			if leftSub then
				leftSub:unsubscribe()
			end
		end, function()
			rightCompleted = true
			tryComplete()
		end)

		return function()
			if leftSub then
				leftSub:unsubscribe()
			end
			if rightSub then
				rightSub:unsubscribe()
			end
		end
	end)
end

local function tagStream(stream, side)
	-- Attach the side label so downstream logic can route to the correct cache.
	local mapped = stream:map(function(entry)
		return {
			side = side,
			entry = entry,
		}
	end)
	-- Only add lifecycle logging if available in this Rx build.
	if mapped.doOnCompleted then
		mapped = mapped:doOnCompleted(function()
			warnf("[JoinObservable] %s upstream completed", side)
		end)
	end
	return mapped
end

function JoinObservable.createJoinObservable(leftStream, rightStream, options)
	-- High-level flow: buffer left/right rows keyed by join key, emit matches immediately,
	-- and periodically evict stale/unmatched rows according to the configured strategy.
	assert(leftStream, "leftStream is required")
	assert(rightStream, "rightStream is required")

	options = options or {}

	local strategy = Strategies.resolve(options.joinType)
	local keySelector = normalizeKeySelector(options.on)
	local expirationConfig = Expiration.normalize(options)
	local mergeSources = options.merge or defaultMerge
	local flushOnComplete = options.flushOnComplete
	local flushOnDispose = options.flushOnDispose
	local gcIntervalSeconds = options.gcIntervalSeconds or options.gc_interval_seconds
	local gcScheduleFn = options.gcScheduleFn or options.gc_schedule_fn
	local debugLifecycle = os.getenv("DEBUG") == "1"
	if flushOnDispose == nil then
		-- Default: emit cached unmatched/expired rows when the downstream cancels,
		-- but only for joins that care about unmatched rows.
		flushOnDispose = strategy.emitUnmatchedLeft or strategy.emitUnmatchedRight
	end
	if flushOnComplete == nil then
		flushOnComplete = true
	end

	local expiredSubject = rx.Subject.create()
	local expiredClosed = false

	local function singleSchemaResult(record)
		-- Wrap a single cache record into a Result to reuse the standard emit path.
		return Result.new():attach(record.schemaName, record.entry)
	end

	local function emitUnmatched(observer, strategy, side, record)
		if not record or record.matched then
			return
		end

		local shouldEmit = (side == "left" and strategy.emitUnmatchedLeft)
			or (side == "right" and strategy.emitUnmatchedRight)

		if not shouldEmit then
			return
		end

		observer:onNext(singleSchemaResult(record))
	end

	local function publishExpiration(side, key, recordEntry, reason)
		if not recordEntry or recordEntry.matched then
			return
		end
		expiredSubject:onNext({
			schema = recordEntry.schemaName,
			key = key,
			reason = reason,
			result = singleSchemaResult(recordEntry),
		})
	end

	local function closeExpiredWith(method, ...)
		if expiredClosed then
			return
		end
		expiredClosed = true
		expiredSubject[method](expiredSubject, ...)
	end

	local observable = rx.Observable.create(function(observer)
		local leftCache, rightCache = {}, {}
		local leftOrder = expirationConfig.left.mode == "count" and {} or nil
		local rightOrder = expirationConfig.right.mode == "count" and {} or nil
		local gcSubscription
		local gcTicking = false
		-- Retention enforcers gate cache growth and drive expiration/onUnmatched emissions.
		local enforceRetention = {
			left = Expiration.createEnforcer(expirationConfig.left, publishExpiration, function(side, record)
				emitUnmatched(observer, strategy, side, record)
			end),
			right = Expiration.createEnforcer(expirationConfig.right, publishExpiration, function(side, record)
				emitUnmatched(observer, strategy, side, record)
			end),
			}

			local function flushCache(cache, side, reason)
				for key, record in pairs(cache) do
					cache[key] = nil
					publishExpiration(side, key, record, reason)
					emitUnmatched(observer, strategy, side, record)
				end
			end

			local function handleMatch(leftRecord, rightRecord)
				leftRecord.matched = true
				rightRecord.matched = true
				strategy.onMatch(observer, leftRecord, rightRecord)
			end

			local closed = false

			local function flushBoth(reason)
				if closed then
					return
				end
				closed = true
				-- When completion/disposal hits, emit everything still buffered for visibility.
				flushCache(leftCache, "left", reason)
				flushCache(rightCache, "right", reason)
			end

			local function upsertCacheEntry(cache, key, entry, schemaName)
				local record = cache[key]
				if record then
					record.entry = entry
					record.matched = false
					record.key = key
					record.schemaName = schemaName
				else
					record = {
						entry = entry,
						matched = false,
						key = key,
						schemaName = schemaName,
					}
					cache[key] = record
				end
				return record
			end

			local function runPeriodicGC()
				if not gcIntervalSeconds or gcIntervalSeconds <= 0 then
					return
				end

				-- Auto-detect scheduler or use provided gcScheduleFn for periodic GC.
				local scheduleFn = gcScheduleFn
				if not scheduleFn then
					local scheduler = rx.scheduler and rx.scheduler.get and rx.scheduler.get()
					if scheduler and tostring(scheduler) == "TimeoutScheduler" and scheduler.schedule then
						scheduleFn = function(delaySeconds, fn)
							return scheduler:schedule(fn, (delaySeconds or 0) * 1000)
						end
						if debugLifecycle then
							warnf("[JoinObservable] gcIntervalSeconds using TimeoutScheduler")
						end
					end
				end

				if not scheduleFn then
					-- Warn loudly since GC was requested but cannot run.
					warnf("[JoinObservable] gcIntervalSeconds configured but no scheduler available; GC disabled")
					return
				elseif debugLifecycle then
					warnf("[JoinObservable] gcIntervalSeconds using custom scheduler")
				end

				local function tick()
					if gcTicking then
						return
					end
					gcTicking = true
					enforceRetention.left(leftCache, leftOrder, "left")
					enforceRetention.right(rightCache, rightOrder, "right")
					gcSubscription = scheduleFn(gcIntervalSeconds, function()
						gcTicking = false
						tick()
					end)
					if not gcSubscription then
						gcTicking = false
					end
				end

				gcSubscription = scheduleFn(gcIntervalSeconds, tick)
			end

			local function handleEntry(side, cache, otherCache, order, entry)
				local meta = Schema.assertRecordHasMeta(entry, side)
				local schemaName = meta.schema
				local ok, key = pcall(keySelector, entry, side, schemaName)
				if not ok then
					warnf("Dropped %s entry because key selector errored: %s", side, tostring(key))
					return
				end
				if key == nil then
					warnf("Dropped %s entry because join key resolved to nil", side)
					return
				end
				meta.joinKey = key
				local record = upsertCacheEntry(cache, key, entry, schemaName)

				if order then
					for i = 1, #order do
						if order[i] == key then
							table.remove(order, i)
							break
						end
					end
					table.insert(order, key)
				end

				local other = otherCache[key]
				if other then
					if side == "left" then
						handleMatch(record, other)
					else
						handleMatch(other, record)
					end
				end

				-- Evict stale rows each time we insert to avoid unbounded growth.
				enforceRetention[side](cache, order, side)
			end

			local leftTagged = tagStream(leftStream, "left")
			local rightTagged = tagStream(rightStream, "right")
		local merged = mergeSources(leftTagged, rightTagged)
		if merged.doOnCompleted then
			merged = merged:doOnCompleted(function()
				warnf("[JoinObservable] merged stream completed")
			end)
		end
		if merged.doOnError then
			merged = merged:doOnError(function(err)
				warnf("[JoinObservable] merged stream error %s", tostring(err))
			end)
		end
		assert(merged and merged.subscribe, "mergeSources must return an observable")

		local subscription
		subscription = merged:subscribe(function(record)
			if type(record) ~= "table" then
				warnf("Ignoring record emitted as %s (expected table)", type(record))
				return
			end

			local side = record.side
			local entry = record.entry

			if side == "left" then
				handleEntry("left", leftCache, rightCache, leftOrder, entry)
			elseif side == "right" then
				handleEntry("right", rightCache, leftCache, rightOrder, entry)
			end
			end, function(err)
				observer:onError(err)
				closeExpiredWith("onError", err)
			end, function()
				if flushOnComplete then
					flushBoth("completed")
				end
				observer:onCompleted()
				closeExpiredWith("onCompleted")
				if debugLifecycle then
					warnf("[JoinObservable] completed join stream")
				end
			end)
		runPeriodicGC()

		return function()
			if subscription then
				subscription:unsubscribe()
			end
			if flushOnDispose then
				-- Emit best-effort leftovers before shutting down on manual disposal.
				flushBoth("disposed")
			end
			closeExpiredWith("onCompleted")
			if debugLifecycle then
				warnf("[JoinObservable] disposed join stream")
			end
			if gcSubscription and gcSubscription.unsubscribe then
				gcSubscription:unsubscribe()
			end
		end
	end)

	return observable, expiredSubject
end

local function copyMetaDefaults(targetRecord, fallbackMeta, schemaName)
	targetRecord.RxMeta = targetRecord.RxMeta or {}
	targetRecord.RxMeta.schema = schemaName
	-- Explainer: downstream joins rely on schemaVersion/joinKey/sourceTime even if
	-- the mapper replaces the payload, so we backfill from the original metadata.
	if targetRecord.RxMeta.schemaVersion == nil then
		targetRecord.RxMeta.schemaVersion = fallbackMeta and fallbackMeta.schemaVersion or nil
	end
	if targetRecord.RxMeta.joinKey == nil then
		targetRecord.RxMeta.joinKey = fallbackMeta and fallbackMeta.joinKey or nil
	end
	if targetRecord.RxMeta.sourceTime == nil then
		targetRecord.RxMeta.sourceTime = fallbackMeta and fallbackMeta.sourceTime or nil
	end
end

---Creates a derived observable by forwarding one schema from an upstream JoinResult stream.
---@param resultStream rx.Observable
---@param opts table
---@return rx.Observable
function JoinObservable.chain(resultStream, opts)
	assert(resultStream and resultStream.subscribe, "resultStream must be an observable")

	opts = opts or {}
	local from = opts.schema or opts.from
	assert(from, "opts.from (or opts.schema) is required")

	local mappings = {}
	if type(from) == "string" then
		table.insert(mappings, {
			schema = from,
			renameTo = opts.as or opts.renameTo or from,
			map = opts.map or opts.projector,
		})
	elseif type(from) == "table" then
		for _, entry in ipairs(from) do
			assert(type(entry.schema) == "string" and entry.schema ~= "", "each entry in from must define schema")
			table.insert(mappings, {
				schema = entry.schema,
				renameTo = entry.renameTo or entry.schema,
				map = entry.map or entry.projector,
			})
		end
	else
		error("opts.from must be string or table")
	end

	local derived = rx.Observable.create(function(observer)
		-- Explainer: wrapping in `Observable.create` gives us lazy subscription
		-- semantics, so we avoid dangling Subjects and respect downstream disposal.
		local subscription
		subscription = resultStream:subscribe(function(result)
			if getmetatable(result) ~= Result then
				observer:onError("JoinObservable.chain expects upstream JoinResult values")
				return
			end

			for _, mapping in ipairs(mappings) do
				local selection = Result.selectSchemas(result, { [mapping.schema] = mapping.renameTo })
				local record = selection:get(mapping.renameTo)
					if record then
						local output = record
						if mapping.map then
							local ok, transformed = pcall(mapping.map, record, result)
							if not ok then
							observer:onError(transformed)
							return
						end
						if transformed ~= nil then
							output = transformed
						end
					end
					if type(output) ~= "table" then
						observer:onError("JoinObservable.chain expects mapper to return a table")
						return
					end
					copyMetaDefaults(output, record.RxMeta, mapping.renameTo)
					observer:onNext(output)
				end
			end
		end, function(err)
			observer:onError(err)
		end, function()
			observer:onCompleted()
		end)

		return function()
			-- Explainer: cascade unsubscription upstream so chained joins don't keep
			-- consuming records after the downstream observer is gone.
			if subscription then
				subscription:unsubscribe()
			end
		end
	end)

	return derived
end

function JoinObservable.setWarningHandler(handler)
	return warnings.setWarningHandler(handler)
end

return JoinObservable
