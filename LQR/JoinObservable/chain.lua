local rx = require("reactivex")
local Result = require("LQR.JoinObservable.result")
local Log = require("LQR.util.log").withTag("join")

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
	if fallbackMeta == nil and targetRecord.RxMeta.joinKey == nil then
		Log:warn("JoinObservable.chain emitted record without RxMeta.joinKey; mapper should preserve metadata")
	end
end

local Chain = {}

---Creates a derived observable by forwarding one schema from an upstream JoinResult stream.
---@param resultStream rx.Observable
---@param opts table
---@return rx.Observable
function Chain.chain(resultStream, opts)
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
		local function fail(err)
			if subscription then
				subscription:unsubscribe()
				subscription = nil
			end
			observer:onError(err)
		end

		subscription = resultStream:subscribe(function(result)
			if getmetatable(result) ~= Result then
				fail("JoinObservable.chain expects upstream JoinResult values")
				return
			end

			local recordCache, metaCache = {}, {}
			local function resolveSource(schema)
				if recordCache[schema] == nil then
					local source = result:get(schema)
					recordCache[schema] = source or false
					metaCache[schema] = source and (source.RxMeta or nil) or nil
				end
				local cached = recordCache[schema]
				return cached ~= false and cached or nil, metaCache[schema]
			end

			for _, mapping in ipairs(mappings) do
				local sourceRecord, sourceMeta = resolveSource(mapping.schema)
				if sourceRecord then
					-- Each branch gets its own copy to keep mapper mutations isolated.
					local recordCopy = Result.shallowCopyRecord(sourceRecord, mapping.renameTo)
					local output = recordCopy
					if mapping.map then
						local ok, transformed = pcall(mapping.map, recordCopy, result)
						if not ok then
							fail(transformed)
							return
						end
						if transformed ~= nil then
							output = transformed
						end
					end
					if type(output) ~= "table" then
						fail("JoinObservable.chain expects mapper to return a table")
						return
					end
					local fallbackMeta = sourceMeta or (result.RxMeta and result.RxMeta.schemaMap and result.RxMeta.schemaMap[mapping.schema])
					copyMetaDefaults(output, fallbackMeta, mapping.renameTo)
					observer:onNext(output)
				else
					Log:warn("JoinObservable.chain skipping missing schema '%s'", mapping.schema)
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

return Chain
