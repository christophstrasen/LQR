-- Expiration utilities that prune cached join rows based on count/interval/predicate rules.
local warnings = require("JoinObservable.warnings")

local warnf = warnings.warnf

local Expiration = {}

local DEFAULT_MAX_CACHE_SIZE = 5

local function normalizeSingle(options, config)
	config = config or {}
	local mode = (config.mode or options.mode or "count"):lower()

	if mode == "time" then
		local ttl = config.ttl or options.ttl or 60
		config = {
			field = config.field or options.field or "time",
			offset = ttl,
			currentFn = config.currentFn or options.currentFn or os.time,
			reason = config.reason or options.reason or "expired_time",
		}
		mode = "interval"
	end

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
		local field = config.field or options.field
		assert(field, "expirationWindow.field is required for interval mode")
		local offset = config.offset or options.offset
		assert(type(offset) == "number" and offset >= 0, "expirationWindow.offset must be a non-negative number")
		local currentFn = config.currentFn or options.currentFn or os.time
		assert(type(currentFn) == "function", "expirationWindow.currentFn must be a function")
		return {
			mode = "interval",
			field = field,
			offset = offset,
			currentFn = currentFn,
			reason = config.reason or options.reason or "expired_interval",
		}
	elseif mode == "predicate" then
		local predicate = config.predicate or config.evaluator
		assert(type(predicate) == "function", "expirationWindow.predicate must be a function")
		local currentFn = config.currentFn or options.currentFn or os.time
		assert(type(currentFn) == "function", "expirationWindow.currentFn must be a function")
		return {
			mode = "predicate",
			predicate = predicate,
			currentFn = currentFn,
			reason = config.reason or options.reason or "expired_predicate",
		}
	else
		error(("Unsupported expirationWindow mode '%s'"):format(tostring(config.mode)))
	end
end

function Expiration.normalize(options)
	options = options or {}
	local config = options.expirationWindow or {}
	if config.left or config.right then
		local defaults = normalizeSingle(options, config)
		return {
			left = normalizeSingle(options, config.left or defaults),
			right = normalizeSingle(options, config.right or defaults),
		}
	end

	local normalized = normalizeSingle(options, config)
	return {
		left = normalized,
		right = normalized,
	}
end

function Expiration.createEnforcer(expirationConfig, publishExpirationFn, emitUnmatchedFn)
	if expirationConfig.mode == "count" then
		local maxItems = expirationConfig.maxItems
		return function(cache, order, side)
			order = order or {}
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
		local offset = expirationConfig.offset
		local currentFn = expirationConfig.currentFn
		local reason = expirationConfig.reason
		return function(cache, order, side)
			local now = currentFn()
			for key, record in pairs(cache) do
				local entry = record.entry
				local meta = entry and entry.RxMeta
				local value = meta and meta.sourceTime or (entry and entry[field])
				if type(value) ~= "number" then
					warnf("Cannot evaluate interval expiration for %s entry: field '%s' missing or not numeric", side, field)
				elseif now - value > offset then
					cache[key] = nil
					publishExpirationFn(side, key, record, reason)
					emitUnmatchedFn(side, record)
					if order then
						for i = #order, 1, -1 do
							if order[i] == key then
								table.remove(order, i)
								break
							end
						end
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
				now = currentFn(),
				nowFn = currentFn,
			}
			for key, record in pairs(cache) do
				local keep = true
				local ok, result = pcall(predicate, record.entry, side, ctx)
				if not ok then
					warnf("expirationWindow predicate errored for %s entry: %s", side, tostring(result))
				else
					keep = not not result
				end

				if not keep then
					cache[key] = nil
					publishExpirationFn(side, key, record, reason)
					emitUnmatchedFn(side, record)
					if order then
						for i = #order, 1, -1 do
							if order[i] == key then
								table.remove(order, i)
								break
							end
						end
					end
				end
			end
		end
	end
end

Expiration.DEFAULT_MAX_CACHE_SIZE = DEFAULT_MAX_CACHE_SIZE

return Expiration
