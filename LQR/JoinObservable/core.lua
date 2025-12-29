-- Core join implementation that pairs two schema-tagged streams and emits joined results.
local rx = require("reactivex")
local Schema = require("LQR/JoinObservable/schema")
local Result = require("LQR/JoinObservable/result")
local Strategies = require("LQR/JoinObservable/strategies")
local Expiration = require("LQR/JoinObservable/expiration")
local OrderQueue = require("LQR/util/order_queue")
local LogModule = require("LQR/util/log")
local Log = LogModule.withTag("join")

local JoinObservableCore = {}

local function safeGetenv(name)
	if type(os) == "table" and type(os.getenv) == "function" then
		return os.getenv(name)
	end
	return nil
end

-- Best-effort structured formatter for payload logging.
local function formatForLog(value)
	-- Fallback: simple pretty printer with cycle protection.
	local function encode(v, depth, seen)
		if depth <= 0 then
			return "..."
		end
		local t = type(v)
		if t == "table" then
			if seen[v] then
				return "<cycle>"
			end
			seen[v] = true
			local keys = {}
			for k in pairs(v) do
				keys[#keys + 1] = k
			end
			table.sort(keys, function(a, b)
				return tostring(a) < tostring(b)
			end)
			local parts = {}
			for _, k in ipairs(keys) do
				parts[#parts + 1] = string.format("%s=%s", tostring(k), encode(v[k], depth - 1, seen))
			end
			seen[v] = nil
			return "{" .. table.concat(parts, ", ") .. "}"
		elseif t == "string" then
			return string.format("%q", v)
		else
			return tostring(v)
		end
	end

	return encode(value, 3, {})
end

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

local function tagStream(stream, side, debugf)
	debugf = debugf or function() end
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
			debugf("%s upstream completed", side)
		end)
	end
	return mapped
end

function JoinObservableCore.createJoinObservable(leftStream, rightStream, options)
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
	local gcOnInsert = options.gcOnInsert
	local gcIntervalSeconds = options.gcIntervalSeconds or options.gc_interval_seconds
	local gcScheduleFn = options.gcScheduleFn or options.gc_schedule_fn
	local viz = options.viz
	local vizEmit = viz and viz.emit
	local baseViz = vizEmit
			and {
				stepIndex = viz.stepIndex,
				depth = viz.depth,
				joinType = options.joinType,
			}
		or nil
	local debugLifecycle = safeGetenv("DEBUG") == "1"
	local function sanitizeMessage(message)
		local msg = tostring(message or "")
		return msg:gsub(":", "COLON")
	end
	local function writeDebug(line)
		local cleaned = sanitizeMessage(line)
		if io and io.stderr and io.stderr.write then
			io.stderr:write(cleaned .. "\n")
		else
			print(cleaned)
		end
	end
	local function debugf(fmt, ...)
		if not debugLifecycle then
			return
		end
		local ok, msg = pcall(string.format, fmt, ...)
		if ok then
			writeDebug("[JoinObservable debug] " .. msg)
		end
	end
	local function emitViz(kind, payload)
		if not vizEmit or not baseViz then
			return
		end
		local event = {
			kind = kind,
			stepIndex = baseViz.stepIndex,
			depth = baseViz.depth,
			joinType = baseViz.joinType,
		}
		if type(payload) == "table" then
			for key, value in pairs(payload) do
				event[key] = value
			end
		end
		local ok, err = pcall(vizEmit, event)
		if not ok then
			Log:warn("Visualization sink failed - %s", tostring(err))
		end
	end
	if gcOnInsert == nil then
		gcOnInsert = true
	end
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

		local meta = record.entry and record.entry.RxMeta
		Log:info(
			"[unmatched] side=%s schema=%s key=%s id=%s sourceTime=%s",
			side,
			tostring(record.schemaName),
			tostring(record.key),
			meta and tostring(meta.id) or "nil",
			meta and tostring(meta.sourceTime) or "nil"
		)
		Log:debug(
			"[unmatched] side=%s schema=%s key=%s entry=%s",
			side,
			tostring(record.schemaName),
			tostring(record.key),
			tostring(record.entry)
		)

		if baseViz then
			emitViz("unmatched", {
				side = side,
				schema = record.schemaName,
				key = record.key,
				id = meta and meta.id or nil,
				sourceTime = meta and meta.sourceTime or nil,
				entry = record.entry,
			})
		end
		observer:onNext(singleSchemaResult(record))
	end

	local function publishExpiration(side, key, recordEntry, reason)
		if not recordEntry then
			return
		end
		local meta = recordEntry.entry and recordEntry.entry.RxMeta
		local matchedFlag = recordEntry.matched == true
		Log:info(
			"[expire] matched=%s side=%s schema=%s key=%s reason=%s id=%s sourceTime=%s",
			tostring(matchedFlag),
			side,
			tostring(recordEntry.schemaName),
			tostring(key),
			tostring(reason),
			meta and tostring(meta.id) or "nil",
			meta and tostring(meta.sourceTime) or "nil"
		)
		Log:debug(
			"[expire] matched=%s side=%s schema=%s key=%s reason=%s entry=%s",
			tostring(matchedFlag),
			side,
			tostring(recordEntry.schemaName),
			tostring(key),
			tostring(reason),
			formatForLog(recordEntry.entry)
		)
		if baseViz then
			emitViz("expire", {
				side = side,
				schema = recordEntry.schemaName,
				key = key,
				reason = reason,
				matched = matchedFlag,
				id = meta and meta.id or nil,
				sourceTime = meta and meta.sourceTime or nil,
				entry = recordEntry.entry,
			})
		end
		expiredSubject:onNext({
			origin = "join",
			schema = recordEntry.schemaName,
			key = key,
			reason = reason,
			matched = matchedFlag,
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
		local leftOrder = expirationConfig.left.mode == "count" and OrderQueue.new() or nil
		local rightOrder = expirationConfig.right.mode == "count" and OrderQueue.new() or nil
		local defaultPerKeyBufferSize = options.perKeyBufferSize or 10
		local perKeyBufferConfigured = {
			left = options.perKeyBufferSizeLeft ~= nil,
			right = options.perKeyBufferSizeRight ~= nil,
		}
		local globalPerKeyConfigured = options.perKeyBufferSize ~= nil
		local perKeyBufferSize = {
			left = options.perKeyBufferSizeLeft or defaultPerKeyBufferSize,
			right = options.perKeyBufferSizeRight or defaultPerKeyBufferSize,
		}
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

		local function ensureBuffer(cache, key)
			local buffer = cache[key]
			if not buffer then
				buffer = { entries = {} }
				cache[key] = buffer
			end
			return buffer
		end

		local function removeFromOrder(order, targetRecord)
			if not order then
				return
			end
			if OrderQueue.isOrderQueue(order) then
				OrderQueue.removeRecord(order, targetRecord)
				return
			end
			for i = #order, 1, -1 do
				if order[i].record == targetRecord then
					table.remove(order, i)
					return
				end
			end
		end

		local function evictOldest(buffer)
			if not buffer or not buffer.entries then
				return nil
			end
			return table.remove(buffer.entries, 1)
		end

		local function removeFromBuffer(cache, key, buffer, targetRecord)
			if not buffer or not buffer.entries then
				return
			end
			for i = #buffer.entries, 1, -1 do
				if buffer.entries[i] == targetRecord then
					table.remove(buffer.entries, i)
					break
				end
			end
			if #buffer.entries == 0 then
				cache[key] = nil
			end
		end

		local function flushCache(cache, order, side, reason)
			for key, buffer in pairs(cache) do
				if buffer and buffer.entries then
					for _, record in ipairs(buffer.entries) do
						publishExpiration(side, key, record, reason)
						emitUnmatched(observer, strategy, side, record)
					end
				end
				cache[key] = nil
			end
			if order then
				if OrderQueue.isOrderQueue(order) then
					OrderQueue.clear(order)
				else
					local keys = {}
					for k in pairs(order) do
						keys[#keys + 1] = k
					end
					for i = 1, #keys do
						order[keys[i]] = nil
					end
				end
			end
		end

		local function consumeMatched(side, cache, order, record)
			if not record then
				return
			end
			local buffer = cache[record.key]
			if not buffer or not buffer.entries then
				return
			end
			for i = #buffer.entries, 1, -1 do
				if buffer.entries[i] == record then
					table.remove(buffer.entries, i)
					removeFromOrder(order, record)
					publishExpiration(side, record.key, record, "distinct_match")
					if #buffer.entries == 0 then
						cache[record.key] = nil
					end
					break
				end
			end
		end

		local function handleMatch(leftRecord, rightRecord)
			leftRecord.matched = true
			rightRecord.matched = true
			local leftMeta = leftRecord.entry and leftRecord.entry.RxMeta
			local rightMeta = rightRecord.entry and rightRecord.entry.RxMeta
			local key = leftRecord and leftRecord.key or rightRecord.key
			Log:info(
				"[match] key=%s leftSchema=%s leftId=%s rightSchema=%s rightId=%s",
				tostring(key),
				tostring(leftRecord.schemaName),
				leftMeta and tostring(leftMeta.id) or "nil",
				tostring(rightRecord.schemaName),
				rightMeta and tostring(rightMeta.id) or "nil"
			)
			Log:debug(
				"[match] key=%s leftEntry=%s rightEntry=%s",
				tostring(key),
				tostring(leftRecord.entry),
				tostring(rightRecord.entry)
			)
			if baseViz then
				local function brief(record)
					if not record then
						return nil
					end
					local meta = record.entry and record.entry.RxMeta
					return {
						schema = record.schemaName,
						id = meta and meta.id or nil,
						key = record.key,
						sourceTime = meta and meta.sourceTime or nil,
						entry = record.entry,
					}
				end
				emitViz("match", {
					key = leftRecord and leftRecord.key or rightRecord.key,
					left = brief(leftRecord),
					right = brief(rightRecord),
				})
			end
			strategy.onMatch(observer, leftRecord, rightRecord)
			if options.distinctLeft then
				consumeMatched("left", leftCache, leftOrder, leftRecord)
			end
			if options.distinctRight then
				consumeMatched("right", rightCache, rightOrder, rightRecord)
			end
		end

		local closed = false

		local function flushBoth(reason)
			if closed then
				return
			end
			closed = true
			-- When completion/disposal hits, emit everything still buffered for visibility.
			flushCache(leftCache, leftOrder, "left", reason)
			flushCache(rightCache, rightOrder, "right", reason)
		end

		local function upsertBufferEntry(cache, order, side, key, entry, schemaName)
			local buffer = ensureBuffer(cache, key)
			local capacity = perKeyBufferSize[side] or defaultPerKeyBufferSize
			local shouldWarnOnCapacity = not (perKeyBufferConfigured[side] or globalPerKeyConfigured)
			local record = {
				entry = entry,
				matched = false,
				key = key,
				schemaName = schemaName,
			}
			if capacity and capacity > 0 and #buffer.entries >= capacity then
				local evicted = evictOldest(buffer)
				if evicted then
					removeFromOrder(order, evicted)
					publishExpiration(side, key, evicted, "replaced")
					emitUnmatched(observer, strategy, side, evicted)
					if shouldWarnOnCapacity then
						Log:warn(
							"[buffer] Default buffer size %s reached for %s.%s; consider increasing perKeyBufferSize if not intended",
							tostring(capacity),
							tostring(schemaName),
							tostring(key)
						)
					end
				end
			end
			table.insert(buffer.entries, record)
			if order then
				if OrderQueue.isOrderQueue(order) then
					OrderQueue.push(order, key, record)
				else
					order[#order + 1] = { key = key, record = record }
				end
			end
			return record
		end

		local gcSubscription
		local function cancelGc()
			if not gcSubscription then
				return
			end
			if type(gcSubscription) == "function" then
				gcSubscription()
			elseif gcSubscription.unsubscribe then
				gcSubscription:unsubscribe()
			elseif gcSubscription.dispose then
				gcSubscription:dispose()
			end
			gcSubscription = nil
		end

		local function runInsertGC(triggerSide)
			debugf("per-insert GC sweep (trigger=%s)", triggerSide or "unknown")
			enforceRetention.left(leftCache, leftOrder, "left")
			enforceRetention.right(rightCache, rightOrder, "right")
		end

		local function runPeriodicGC()
			if not gcIntervalSeconds or gcIntervalSeconds <= 0 then
				return
			end

			-- Auto-detect scheduler or use provided gcScheduleFn for periodic GC.
			-- @TODO: add instrumentation for GC cost and auto-tune gcOnInsert/gcIntervalSeconds based on load.
			local scheduleFn = gcScheduleFn
			if not scheduleFn and rx.scheduler and rx.scheduler.schedule then
				scheduleFn = function(delaySeconds, fn)
					return rx.scheduler.schedule(fn, delaySeconds or 0)
				end
				debugf("gcIntervalSeconds using rx.scheduler helper")
			end
			if not scheduleFn then
				local scheduler = rx.scheduler and rx.scheduler.get and rx.scheduler.get()
				if scheduler and scheduler.schedule then
					if tostring(scheduler) == "TimeoutScheduler" then
						scheduleFn = function(delaySeconds, fn)
							return scheduler:schedule(fn, (delaySeconds or 0) * 1000)
						end
						debugf("gcIntervalSeconds using TimeoutScheduler")
					else
						scheduleFn = function(delaySeconds, fn)
							return scheduler:schedule(fn, delaySeconds or 0)
						end
						debugf("gcIntervalSeconds using scheduler=%s", tostring(scheduler))
					end
				end
			end

			if not scheduleFn then
				-- Warn loudly since GC was requested but cannot run.
				Log:warn("[JoinObservable] gcIntervalSeconds configured but no scheduler available; GC disabled")
				return
			else
				debugf("gcIntervalSeconds using custom scheduler")
			end

			local function tick()
				if gcTicking then
					return
				end
				gcTicking = true
				debugf("periodic GC tick (interval=%ss)", tostring(gcIntervalSeconds))
				runInsertGC("periodic")
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
				Log:warn("Dropped %s entry because key selector errored - %s", side, tostring(key))
				return
			end
			if key == nil then
				Log:warn("Dropped %s entry because join key resolved to nil", side)
				return
			end
			meta.joinKey = key
			if LogModule.isEnabled("trace", Log.tag) then
				Log:trace(
					"[input] side=%s schema=%s key=%s id=%s sourceTime=%s schemaVersion=%s",
					side,
					tostring(schemaName),
					tostring(key),
					meta and tostring(meta.id) or "nil",
					meta and tostring(meta.sourceTime) or "nil",
					meta and tostring(meta.schemaVersion) or "nil"
				)
			end
			if LogModule.isEnabled("debug", Log.tag) then
				Log:debug(
					"[input payload] side=%s schema=%s key=%s entry=%s",
					side,
					tostring(schemaName),
					tostring(key),
					formatForLog(entry)
				)
			end
			local record = upsertBufferEntry(cache, order, side, key, entry, schemaName)

			if baseViz then
				emitViz("input", {
					side = side,
					schema = schemaName,
					key = key,
					id = meta.id,
					sourceTime = meta.sourceTime,
					schemaVersion = meta.schemaVersion,
					entry = entry,
				})
			end

			local otherBuffer = otherCache[key]
			if otherBuffer and otherBuffer.entries then
				for _, partner in ipairs(otherBuffer.entries) do
					if side == "left" then
						handleMatch(record, partner)
					else
						handleMatch(partner, record)
					end
				end
			end

			-- Evict stale rows each time we insert to avoid unbounded growth.
			if gcOnInsert then
				runInsertGC(side)
			end
		end

		local leftTagged = tagStream(leftStream, "left", debugf)
		local rightTagged = tagStream(rightStream, "right", debugf)
		local merged = mergeSources(leftTagged, rightTagged)
		if merged.doOnCompleted then
			merged = merged:doOnCompleted(function()
				debugf("merged stream completed")
			end)
		end
		if merged.doOnError then
			merged = merged:doOnError(function(err)
				debugf("merged stream error %s", tostring(err))
			end)
		end
		assert(merged and merged.subscribe, "mergeSources must return an observable")

		local subscription
		subscription = merged:subscribe(function(record)
			if type(record) ~= "table" then
				Log:warn("Ignoring record emitted as %s (expected table)", type(record))
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
			flushBoth("error")
			cancelGc()
			observer:onError(err)
			closeExpiredWith("onError", err)
		end, function()
			if flushOnComplete then
				flushBoth("completed")
			end
			observer:onCompleted()
			closeExpiredWith("onCompleted")
			debugf("completed join stream")
			cancelGc()
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
			debugf("disposed join stream")
			cancelGc()
		end
	end)

	return observable, expiredSubject
end

return JoinObservableCore
