-- Expiration utilities that prune cached join rows based on count/interval/predicate rules.
local Log = require("LQR/util/log").withTag("join")
local OrderQueue = require("LQR/util/order_queue")

local Expiration = {}

local DEFAULT_MAX_CACHE_SIZE = 5

local function default_now()
	if os and type(os.time) == "function" then
		return os.time
	end
	return function()
		return 0
	end
end

local function normalizeSingle(options, config)
	config = config or {}
	local mode = (config.mode or options.mode or "count"):lower()

	if mode == "time" then
		local ttl = config.ttl or options.ttl or 60
		config = {
			field = config.field or options.field or "time",
			offset = ttl,
			currentFn = config.currentFn or options.currentFn or default_now(),
			reason = config.reason or options.reason or "expired_time",
		}
		mode = "interval"
	end

	local function resolveMaxItems()
		local maxItems = config.maxItems or config.maxCacheSize or options.maxCacheSize or DEFAULT_MAX_CACHE_SIZE
		assert(type(maxItems) == "number" and maxItems >= 1, "joinWindow.maxItems must be a positive number")
		return maxItems
	end

	if mode == "count" then
		return {
			mode = "count",
			maxItems = resolveMaxItems(),
		}
	elseif mode == "interval" then
		local field = config.field or options.field
		assert(field, "joinWindow.field is required for interval mode")
		local offset = config.offset or options.offset
		assert(type(offset) == "number" and offset >= 0, "joinWindow.offset must be a non-negative number")
		local currentFn = config.currentFn or options.currentFn or default_now()
		assert(type(currentFn) == "function", "joinWindow.currentFn must be a function")
		return {
			mode = "interval",
			field = field,
			offset = offset,
			currentFn = currentFn,
			reason = config.reason or options.reason or "expired_interval",
		}
	elseif mode == "predicate" then
		local predicate = config.predicate or config.evaluator
		assert(type(predicate) == "function", "joinWindow.predicate must be a function")
		local currentFn = config.currentFn or options.currentFn or default_now()
		assert(type(currentFn) == "function", "joinWindow.currentFn must be a function")
		return {
			mode = "predicate",
			predicate = predicate,
			currentFn = currentFn,
			reason = config.reason or options.reason or "expired_predicate",
		}
	else
		error(("Unsupported joinWindow mode '%s'"):format(tostring(config.mode)))
	end
end

function Expiration.normalize(options)
	options = options or {}
	local config = options.joinWindow or {}
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
			local isQueue = OrderQueue.isOrderQueue(order)
			while (isQueue and order.count or #order) > maxItems do
				local oldest = isQueue and OrderQueue.pop(order) or table.remove(order, 1)
				local key, record
				if type(oldest) == "table" then
					key = oldest.key
					record = oldest.record
				else
					key = oldest
					local buffer = cache[key]
					record = buffer and buffer.entries and buffer.entries[1] or nil
				end
				local buffer = cache[key]
				if buffer and buffer.entries then
					for i = #buffer.entries, 1, -1 do
						if buffer.entries[i] == record then
							table.remove(buffer.entries, i)
							break
						end
					end
					if #buffer.entries == 0 then
						cache[key] = nil
					end
				end
				publishExpirationFn(side, key, record, "evicted")
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
			for key, buffer in pairs(cache) do
				if buffer and buffer.entries then
					for i = #buffer.entries, 1, -1 do
						local entry = buffer.entries[i].entry
						local meta = entry and entry.RxMeta
						local value = meta and meta.sourceTime or (entry and entry[field])
						if type(value) ~= "number" then
							Log:warn("Cannot evaluate interval expiration for %s entry - field '%s' missing or not numeric", side, field)
						elseif now - value > offset then
							local record = table.remove(buffer.entries, i)
							publishExpirationFn(side, key, record, reason)
							emitUnmatchedFn(side, record)
							if order then
								for j = #order, 1, -1 do
									if order[j].record == record then
										table.remove(order, j)
										break
									end
								end
							end
						end
					end
					if #buffer.entries == 0 then
						cache[key] = nil
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
			for key, buffer in pairs(cache) do
				if buffer and buffer.entries then
					for i = #buffer.entries, 1, -1 do
						local record = buffer.entries[i]
						local keep = true
						local ok, result = pcall(predicate, record.entry, side, ctx)
						if not ok then
							Log:warn("joinWindow predicate errored for %s entry - %s", side, tostring(result))
						else
							keep = not not result
						end

						if not keep then
							table.remove(buffer.entries, i)
							publishExpirationFn(side, key, record, reason)
							emitUnmatchedFn(side, record)
							if order then
								for j = #order, 1, -1 do
									if order[j].record == record then
										table.remove(order, j)
										break
									end
								end
							end
						end
					end
					if #buffer.entries == 0 then
						cache[key] = nil
					end
				end
			end
		end
	end
end

Expiration.DEFAULT_MAX_CACHE_SIZE = DEFAULT_MAX_CACHE_SIZE

return Expiration
