local rx = require("reactivex")
local Schema = require("JoinObservable.schema")
local JoinObservable = require("JoinObservable")

local ScenarioLoader = require("viz.scenario_loader")
local Data = ScenarioLoader.data
local Delay = require("viz.observable_delay")

local Observables = {}

local function emitRecords(records)
	records = records or {}
	return rx.Observable.create(function(observer)
		local cancelled = false
		local index = 1

		local function emitNext()
			if cancelled then
				return
			end
			local record = records[index]
			if not record then
				observer:onCompleted()
				return
			end
			observer:onNext(record)
			index = index + 1
			rx.scheduler.schedule(emitNext, 0)
		end

		rx.scheduler.schedule(emitNext, 0)

		return function()
			cancelled = true
		end
	end)
end

local function buildStream(config, fallbackSchema)
	if not config then
		return nil
	end
	local stream = emitRecords(config.records or {})
	local schemaName = config.schema or fallbackSchema
	stream = Schema.wrap(schemaName, stream, { idField = config.idField or "id" })
	if config.delay then
		stream = Delay.withDelay(stream, config.delay)
	end
	return stream
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

local DEBUG_TIMING = os.getenv("VIZ_DEBUG_TIMING") == "1"

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
			print(string.format(
				"[timing] expired schema=%s id=%s ts=%.3f reason=%s",
				schemaName,
				tostring(id or "?"),
				ts,
				tostring(record.reason)
			))
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

		local join, expired = JoinObservable.createJoinObservable(leftStream, rightStream, {
			on = joinConfig.on or {
				[leftStreamName] = "id",
				[rightStreamName] = "id",
			},
			joinType = joinConfig.joinType or "left",
			expirationWindow = joinExpiration,
		})

		local resultMapper = joinConfig.shapeResult
		if not resultMapper then
			resultMapper = buildJoinResultMapper(joinConfig)
		end
		Observables[resultName] = join:map(resultMapper):filter(nonNil)

		local expiredName = joinConfig.expiredName
		if expiredName then
			if expired then
				local expiredMapper = joinConfig.shapeExpired
				if not expiredMapper then
					expiredMapper = buildExpiredMapper()
				end
				Observables[expiredName] = expired:map(expiredMapper):filter(nonNil)
			else
				Observables[expiredName] = rx.Observable.create(function(observer)
					observer:onCompleted()
				end)
			end
		end
	end
end

return Observables
