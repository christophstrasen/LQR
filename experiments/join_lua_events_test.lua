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

local function describeEntries(label, entries)
	for _, entry in ipairs(entries) do
		print(("[%s seed] schema=%s | id=%d | rand=%d"):format(label, entry.schema, entry.id, entry.randNum))
	end
end

local function createEntries(schema, idRange)
	local entries = {}
	for _, id in ipairs(idRange) do
		table.insert(entries, {
			schema = schema,
			id = id,
			randNum = math.random(20, 50),
		})
	end
	return entries
end

local function scheduleEmitter(label, event, entries)
	scheduler:schedule(function()
		for _, entry in ipairs(entries) do
			logEntry(label, entry)
			event:trigger(entry)
			coroutine.yield(math.random(150, 450) / 1000)
		end

		print(("[%5.2f] [%s] all entries emitted"):format(scheduler.currentTime, label))
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

local leftStream = rx.Observable.fromLuaEvent(leftEvent)
local rightStream = rx.Observable.fromLuaEvent(rightEvent)

local mergedStream = leftStream:merge(rightStream)

local joinedStream = rx.Observable.create(function(observer)
	local leftCache, rightCache = {}, {}

	local subscription = mergedStream:subscribe(function(entry)
		if entry.schema == "left" then
			leftCache[entry.id] = entry
			if rightCache[entry.id] then
				observer:onNext({ left = entry, right = rightCache[entry.id] })
			end
		else
			rightCache[entry.id] = entry
			if leftCache[entry.id] then
				observer:onNext({ left = leftCache[entry.id], right = entry })
			end
		end
	end, function(err)
		observer:onError(err)
	end)

	return function()
		if subscription then
			subscription:unsubscribe()
		end
	end
end)

local subscription = joinedStream:subscribe(function(pair)
	print(("[%5.2f] [JOIN] left(id=%d, rand=%d) <> right(id=%d, rand=%d)"):format(
		scheduler.currentTime,
		pair.left.id,
		pair.left.randNum,
		pair.right.id,
		pair.right.randNum
	))
end, function(err)
	io.stderr:write(("Join stream error: %s\n"):format(err))
end)

while not scheduler:isEmpty() do
	scheduler:update(TIMER_RESOLUTION)
	sleep(TIMER_RESOLUTION)
end

subscription:unsubscribe()
print(("[%5.2f] Join demo complete"):format(scheduler.currentTime))
