require("bootstrap")

local rx = require("reactivex")
local LuaEvent = require("Starlit.LuaEvent")
local io = require("io")

math.randomseed(os.time())

local scheduler = rx.CooperativeScheduler.create()
local TIMER_RESOLUTION = 0.05

local function sleep(seconds)
	local start = os.clock()
	while (os.clock() - start) < seconds do
	end
end

local function logEntry(prefix, entry)
	print(("[%5.2f] [%s] schema=%s | id=%d | rand=%d"):format(
		scheduler.currentTime,
		prefix,
		entry.schema,
		entry.id,
		entry.randNum
	))
end

local function createEntries(schema, idList)
	local output = {}
	for _, id in ipairs(idList) do
		table.insert(output, {
			schema = schema,
			id = id,
			randNum = math.random(20, 50),
		})
	end
	return output
end

local function scheduleEmitter(label, event, entries)
	scheduler:schedule(function()
		for _, entry in ipairs(entries) do
			logEntry(label, entry)
			event:trigger(entry)
			coroutine.yield(math.random(150, 450) / 1000)
		end

		print(("[%5.2f] [%s] completed"):format(scheduler.currentTime, label))
	end)
end

local function describeEntries(label, entries)
	for _, entry in ipairs(entries) do
		print(("[%s seed] schema=%s | id=%d | rand=%d"):format(label, entry.schema, entry.id, entry.randNum))
	end
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

local function createJoinStream(leftStream, rightStream, options)
	options = options or {}
	local joinType = (options.joinType or "inner"):lower()
	local keySelector = normalizeKeySelector(options.on)
	local maxCacheSize = options.maxCacheSize or 5

	local function emitUnmatched(observer, side, record)
		if joinType ~= "outer" or not record or record.matched then
			return
		end

		if side == "left" then
			observer:onNext({ left = record.entry, right = nil })
		else
			observer:onNext({ left = nil, right = record.entry })
		end
	end

	return rx.Observable.create(function(observer)
		local leftCache, rightCache = {}, {}
		local leftOrder, rightOrder = {}, {}

		local function evictIfNeeded(cache, order, side)
			while #order > maxCacheSize do
				local oldestKey = table.remove(order, 1)
				local record = cache[oldestKey]
				cache[oldestKey] = nil
				emitUnmatched(observer, side, record)
			end
		end

	local function handleMatch(leftRecord, rightRecord)
		leftRecord.matched = true
		rightRecord.matched = true
		if joinType == "inner" then
			observer:onNext({ left = leftRecord.entry, right = rightRecord.entry })
		end
	end

		local function handleEntry(side, cache, otherCache, order, entry)
			local key = keySelector(entry)
			if key == nil then
				return
			end

			local record = cache[key]
			if record then
				record.entry = entry
			else
				cache[key] = { entry = entry, matched = false }
			end

			touchKey(order, key)

			local other = otherCache[key]
			if other then
				if side == "left" then
					handleMatch(cache[key], other)
				else
					handleMatch(other, cache[key])
				end
			end

			evictIfNeeded(cache, order, side)
		end

		local merged = leftStream:merge(rightStream)

		local subscription
		subscription = merged:subscribe(function(entry)
			if entry.schema == "left" then
				handleEntry("left", leftCache, rightCache, leftOrder, entry)
			else
				handleEntry("right", rightCache, leftCache, rightOrder, entry)
			end
		end, function(err)
			observer:onError(err)
		end, function()
			if joinType == "outer" then
				for _, record in pairs(leftCache) do
					emitUnmatched(observer, "left", record)
				end
				for _, record in pairs(rightCache) do
					emitUnmatched(observer, "right", record)
				end
			end
			observer:onCompleted()
		end)

		return function()
			if subscription then
				subscription:unsubscribe()
			end
		end
	end)
end

local leftIds = { 1, 2, 3, 4, 5, 6, 7 }
local rightIds = { 4, 5, 6, 7, 8, 9, 10 }

local leftEntries = createEntries("left", leftIds)
local rightEntries = createEntries("right", rightIds)

describeEntries("LEFT", leftEntries)
describeEntries("RIGHT", rightEntries)

local leftEvent = LuaEvent.new()
local rightEvent = LuaEvent.new()

scheduleEmitter("LEFT", leftEvent, leftEntries)
scheduleEmitter("RIGHT", rightEvent, rightEntries)

local leftStream = rx.Observable.fromLuaEvent(leftEvent):take(#leftEntries)
local rightStream = rx.Observable.fromLuaEvent(rightEvent):take(#rightEntries)

local innerJoinStream = createJoinStream(leftStream, rightStream, {
	on = "id",
	joinType = "inner",
	maxCacheSize = 4,
})

local outerJoinStream = createJoinStream(leftStream, rightStream, {
	on = "id",
	joinType = "outer",
	maxCacheSize = 4,
})

local innerSubscription = innerJoinStream:subscribe(function(pair)
	print(("[%5.2f] [INNER] left=%s right=%s"):format(
		scheduler.currentTime,
		pair.left and ("id=" .. pair.left.id .. ",rand=" .. pair.left.randNum) or "nil",
		pair.right and ("id=" .. pair.right.id .. ",rand=" .. pair.right.randNum) or "nil"
	))
end, function(err)
	io.stderr:write(("Inner join error: %s\n"):format(err))
end, function()
	print(("[%5.2f] Inner join completed"):format(scheduler.currentTime))
end)

local outerSubscription = outerJoinStream:subscribe(function(pair)
	print(("[%5.2f] [OUTER] left=%s right=%s"):format(
		scheduler.currentTime,
		pair.left and ("id=" .. pair.left.id .. ",rand=" .. pair.left.randNum) or "nil",
		pair.right and ("id=" .. pair.right.id .. ",rand=" .. pair.right.randNum) or "nil"
	))
end, function(err)
	io.stderr:write(("Outer join error: %s\n"):format(err))
end, function()
	print(("[%5.2f] Outer join completed"):format(scheduler.currentTime))
end)

while not scheduler:isEmpty() do
	scheduler:update(TIMER_RESOLUTION)
	sleep(TIMER_RESOLUTION)
end

innerSubscription:unsubscribe()
outerSubscription:unsubscribe()
