local rx = require("reactivex")
local Log = require("log").withTag("viz-lo")
local Schema = require("JoinObservable.schema")
local JoinObservable = require("JoinObservable.init")

local ScenarioLoader = require("viz_low_level.scenario_loader")
local Data = ScenarioLoader.data
local Delay = require("viz_low_level.observable_delay")

local Observables = {}

local DEBUG_BASE = os.getenv("DEBUG") == "1"
local DEBUG_TIMING = DEBUG_BASE or os.getenv("DEBUG_TIMING") == "1"
local DEBUG_EXPIRED_LOG = DEBUG_BASE or os.getenv("DEBUG_EXPIRED_LOG") == "1"
local DEBUG_STREAM = DEBUG_BASE or os.getenv("DEBUG_STREAM") == "1"
local DEBUG_JOIN_LOG = DEBUG_BASE or os.getenv("DEBUG_JOIN_LOG") == "1"

local loggerSubscriptions = {}
local joinRunCounter = 0

local function emitRecords(records, label)
	records = records or {}
	return rx.Observable.create(function(observer)
		local cancelled = false
		local index = 1

		if DEBUG_STREAM then
			Log:debug("[stream-debug] start len=%d", #records)
		end

		local function emitNext()
			if cancelled then
				return
			end
			local record = records[index]
			if not record then
				if DEBUG_STREAM then
					Log:debug(
						"[stream-debug] source completed%s",
						label and (" subscriber=" .. label) or ""
					)
				end
				observer:onCompleted()
				return
			end
			if DEBUG_STREAM and index % 200 == 1 then
				Log:debug("[stream-debug] emitted index=%d of %d", index, #records)
			end
			observer:onNext(record)
			index = index + 1
			rx.scheduler.schedule(emitNext, 0)
		end

		rx.scheduler.schedule(emitNext, 0)

		return function()
			cancelled = true
			if DEBUG_STREAM then
				Log:debug(
					"[stream-debug] source cancelled%s",
					label and (" subscriber=" .. label) or ""
				)
			end
		end
	end)
end

local function buildStream(config, fallbackSchema)
	if not config then
		return nil
	end
	local source = emitRecords(config.records or {}, fallbackSchema or "unknown")
	local schemaName = config.schema or fallbackSchema
	local stream = Schema.wrap(schemaName, source, { idField = config.idField or "id" })
	if config.delay then
		stream = Delay.withDelay(stream, config.delay)
	end

	-- Multicast the cold stream via a Subject so all consumers share one pass.
	-- We attach the source lazily on the first subscription to avoid emitting
	-- before downstream consumers are attached.
	local subject = rx.Subject.create()
	local connected = false
	local connection
	local function connectSource()
		if connected then
			return
		end
		connected = true
		connection = stream:subscribe(function(value)
			subject:onNext(value)
		end, function(err)
			subject:onError(err)
		end, function()
			subject:onCompleted()
		end)
	end

	if DEBUG_STREAM then
		table.insert(loggerSubscriptions, subject:subscribe(nil, nil, function()
			Log:debug(
				"[stream-debug] subject completed%s",
				schemaName and (" schema=" .. schemaName) or ""
			)
		end))
	end

	return rx.Observable.create(function(observer)
		connectSource()
		local subscription = subject:subscribe(observer)
		return function()
			if subscription then
				subscription:unsubscribe()
			end
			-- We intentionally do not dispose `connection` here; letting it run to
			-- completion ensures all subscribers share the same emission pass.
		end
	end)
end

local streamConfigs = Data.streams or {}
for name, config in pairs(streamConfigs) do
	Observables[name] = buildStream(config, name)
end

local function nonNil(value)
	return value ~= nil
end

local function resolveJoinConfigs()
	if Data.joins and #Data.joins > 0 then
		return Data.joins
	end
	if Data.join then
		return { Data.join }
	end
	return {}
end

local function collectResultSchemas(result)
	if not result or type(result.schemaNames) ~= "function" then
		return nil
	end
	local names = result:schemaNames()
	if not names then
		return nil
	end
	local schemas = {}
	local hasAny = false
	for _, name in ipairs(names) do
		local entry = result:get(name)
		if entry ~= nil then
			schemas[name] = entry
			hasAny = true
		end
	end
	if not hasAny then
		return nil
	end
	return schemas
end

local function logJoin(name, join, expired)
	if not DEBUG_JOIN_LOG or not join then
		return
	end
	joinRunCounter = joinRunCounter + 1
	local runId = joinRunCounter

	local function formatResult(result)
		local schemas = collectResultSchemas(result) or {}
		local parts = {}
		for schemaName, payload in pairs(schemas) do
			local id = payload.RxMeta and payload.RxMeta.id or payload.id
			table.insert(parts, string.format("%s:%s", schemaName, tostring(id)))
		end
		return table.concat(parts, " | ")
	end

	local joinSub = join:subscribe(function(result)
		Log:debug("[join-log] run=%d %s result %s", runId, name, formatResult(result))
	end, function(err)
		Log:error("[join-log] run=%d %s error %s", runId, name, tostring(err))
	end, function()
		Log:debug("[join-log] run=%d %s completed", runId, name)
	end)
	table.insert(loggerSubscriptions, joinSub)

	if expired then
		local expiredSub = expired:subscribe(function(entry)
			local result = entry and entry.result
			Log:debug(
				"[join-log] run=%d %s expired schema=%s key=%s reason=%s result=%s",
				runId,
				name,
				tostring(entry and entry.schema),
				tostring(entry and entry.key),
				tostring(entry and entry.reason),
				formatResult(result)
			)
		end, function(err)
			Log:error("[join-log] run=%d %s expired error %s", runId, name, tostring(err))
		end, function()
			Log:debug("[join-log] run=%d %s expired completed", runId, name)
		end)
		table.insert(loggerSubscriptions, expiredSub)
	end
end

local function buildJoinResultMapper(joinConfig)
	local sources = joinConfig.sources or {}
	local leftSchema = joinConfig.left or sources.left
	local rightSchema = joinConfig.right or sources.right
	return function(result)
		if not result then
			return nil
		end
		local schemas = collectResultSchemas(result)
		if not schemas then
			return nil
		end
		local shaped = { schemas = schemas }
		if leftSchema and rightSchema then
			shaped.match = (schemas[leftSchema] ~= nil) and (schemas[rightSchema] ~= nil)
		end
		return shaped
	end
end

local function buildExpiredMapper()
	return function(record)
		if not record then
			return nil
		end
		local schemaName = record.schema
		local schemas = collectResultSchemas(record.result)
		if not schemas then
			return nil
		end
		if schemaName and not schemas[schemaName] then
			schemaName = nil
		end
		if not schemaName then
			for name in pairs(schemas) do
				schemaName = name
				break
			end
		end
		if not schemaName then
			return nil
		end
		local payload = schemas[schemaName]
		if not payload then
			return nil
		end
		local shaped = {
			schema = schemaName,
			record = payload,
			reason = record.reason,
			expired = true,
			schemas = { [schemaName] = payload },
		}
		if DEBUG_TIMING then
			local payloadMeta = payload.RxMeta or {}
			local id = payloadMeta.id or payload.id or record.key
			local ts = payloadMeta.sourceTime or 0
			Log:debug(
				"[timing] expired schema=%s id=%s ts=%.3f reason=%s",
				schemaName,
				tostring(id or "?"),
				ts,
				tostring(record.reason)
			)
		elseif DEBUG_EXPIRED_LOG then
			local payloadMeta = payload.RxMeta or {}
			local id = payloadMeta.id or payload.id or record.key
			Log:debug(
				"[expired-debug] schema=%s id=%s reason=%s",
				schemaName,
				tostring(id or "?"),
				tostring(record.reason or "unknown")
			)
		end
		return shaped
	end
end

for index, joinConfig in ipairs(resolveJoinConfigs()) do
	local sources = joinConfig.sources or {}
	local leftStreamName = joinConfig.left or sources.left or "customers"
	local rightStreamName = joinConfig.right or sources.right or "orders"
	local leftStream = Observables[leftStreamName]
	local rightStream = Observables[rightStreamName]
	if leftStream and rightStream then
		local resultName = joinConfig.name or joinConfig.resultName or string.format("join_%d", index)
		local joinExpiration = joinConfig.expirationWindow
		assert(
			joinExpiration,
			string.format("Join config '%s' must provide expirationWindow", resultName)
		)

		local rawJoin, rawExpired = JoinObservable.createJoinObservable(leftStream, rightStream, {
			on = joinConfig.on or {
				[leftStreamName] = "id",
				[rightStreamName] = "id",
			},
			joinType = joinConfig.joinType or "left",
			expirationWindow = joinExpiration,
			gcIntervalSeconds = joinConfig.gcIntervalSeconds,
			gcScheduleFn = joinConfig.gcScheduleFn,
			gcOnInsert = joinConfig.gcOnInsert,
		})

		-- Share join/expired streams so all consumers observe the same run.
		local joinSubject = rx.Subject.create()
		local expiredSubject = rawExpired and rx.Subject.create() or nil
		local joinConnected = false
		local function connectJoin()
			if joinConnected then
				return
			end
			joinConnected = true

			local runId = joinRunCounter + 1
			joinRunCounter = runId

			local joinConn = rawJoin:subscribe(function(value)
				joinSubject:onNext(value)
			end, function(err)
				joinSubject:onError(err)
				if DEBUG_JOIN_LOG then
					Log:error("[join-raw] run=%d %s error %s", runId, resultName, tostring(err))
				end
			end, function()
				joinSubject:onCompleted()
				if DEBUG_JOIN_LOG then
					Log:debug("[join-log] run=%d %s raw completed", runId, resultName)
					Log:debug("[join-raw] run=%d %s completed", runId, resultName)
				end
			end)
			table.insert(loggerSubscriptions, joinConn)
			if rawExpired and expiredSubject then
				local expiredConn = rawExpired:subscribe(function(value)
					expiredSubject:onNext(value)
				end, function(err)
					expiredSubject:onError(err)
					if DEBUG_JOIN_LOG then
						Log:error("[join-raw] run=%d %s expired error %s", runId, resultName, tostring(err))
					end
				end, function()
					expiredSubject:onCompleted()
					if DEBUG_JOIN_LOG then
						Log:debug("[join-log] run=%d %s raw expired completed", runId, resultName)
						Log:debug("[join-raw] run=%d %s expired completed", runId, resultName)
					end
				end)
				table.insert(loggerSubscriptions, expiredConn)
			end
		end

		local join = rx.Observable.create(function(observer)
			connectJoin()
			return joinSubject:subscribe(observer)
		end)
		local expired = expiredSubject
			and rx.Observable.create(function(observer)
				connectJoin()
				return expiredSubject:subscribe(observer)
			end)
			or nil

		local resultMapper = joinConfig.shapeResult
		if not resultMapper then
			resultMapper = buildJoinResultMapper(joinConfig)
		end
		Observables[resultName] = join:map(resultMapper):filter(nonNil)
		logJoin(resultName, join, expired)

		local expiredName = joinConfig.expiredName
		if expiredName then
			if expired then
				local expiredMapper = joinConfig.shapeExpired
				if not expiredMapper then
					expiredMapper = buildExpiredMapper()
				end
				local mappedExpired = expired:map(expiredMapper):filter(nonNil)
				if DEBUG_EXPIRED_LOG and not DEBUG_TIMING then
					-- Explainer: tap the expired stream so we still see completions if the UI drains slow.
					mappedExpired:subscribe(function(value)
						local reason = value.reason or (value.expired and "expired") or "unknown"
						local schema = value.schema or "unknown"
						print(string.format("[expired-debug] emitted schema=%s reason=%s", schema, reason))
					end)
				end
				Observables[expiredName] = mappedExpired
		else
			Observables[expiredName] = rx.Observable.create(function(observer)
				observer:onCompleted()
			end)
		end
		end
	end
end

return Observables
