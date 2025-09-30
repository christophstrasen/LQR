local warnings = require("JoinObservable.warnings")

local warnf = warnings.warnf

local Expiration = {}

local DEFAULT_MAX_CACHE_SIZE = 5

function Expiration.normalize(options)
	options = options or {}
	local config = options.expirationWindow or {}
	local mode = (config.mode or "count"):lower()

	if mode == "time" then
		local offset = config.offset or config.maxAge or config.maxAgeMs or config.ttl or 60
		config = {
			field = config.field or "time",
			maxAge = offset,
			currentFn = config.currentFn or os.time,
			reason = config.reason or "expired_time",
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

function Expiration.createEnforcer(expirationConfig, publishExpirationFn, emitUnmatchedFn)
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

Expiration.DEFAULT_MAX_CACHE_SIZE = DEFAULT_MAX_CACHE_SIZE

return Expiration
