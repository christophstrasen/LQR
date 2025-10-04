require("bootstrap")

local rx = require("reactivex")
local LuaEvent = require("Starlit.LuaEvent")
local JoinObservable = require("JoinObservable")
local Schema = require("JoinObservable.schema")
local io = require("io")

local createJoinObservable = JoinObservable.createJoinObservable

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

local function describeExpired(prefix, packet)
	if not packet then
		return
	end

	local alias = packet.alias or "unknown"
	local entry = packet.result and packet.result:get(alias)
	print(("[%5.2f] [%s EXPIRED] alias=%s key=%s reason=%s entry=%s"):format(
		scheduler.currentTime,
		prefix,
		alias,
		tostring(packet.key),
		packet.reason or "unknown",
		entry and ("id=" .. tostring(entry.id) .. ",rand=" .. tostring(entry.randNum)) or "nil"
	))
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

local leftStream = Schema.wrap("luaEventLeft", rx.Observable.fromLuaEvent(leftEvent):take(#leftEntries))
local rightStream = Schema.wrap("luaEventRight", rx.Observable.fromLuaEvent(rightEvent):take(#rightEntries))

local innerJoinStream = createJoinObservable(leftStream, rightStream, {
	on = "id",
	joinType = "inner",
	maxCacheSize = 4,
})

local outerJoinStream, outerExpired = createJoinObservable(leftStream, rightStream, {
	on = "id",
	joinType = "outer",
	maxCacheSize = 4,
})

local antiOuterJoinStream, antiExpired = createJoinObservable(leftStream, rightStream, {
	on = "id",
	joinType = "anti_outer",
	maxCacheSize = 4,
})

local function formatEntry(record)
	return record and ("id=" .. record.id .. ",rand=" .. record.randNum) or "nil"
end

local innerSubscription = innerJoinStream:subscribe(function(result)
	local leftRecord = result:get("luaEventLeft")
	local rightRecord = result:get("luaEventRight")
	print(("[%5.2f] [INNER] left=%s right=%s"):format(
		scheduler.currentTime,
		formatEntry(leftRecord),
		formatEntry(rightRecord)
	))
end, function(err)
	io.stderr:write(("Inner join error: %s\n"):format(err))
end, function()
	print(("[%5.2f] Inner join completed"):format(scheduler.currentTime))
end)

local outerSubscription = outerJoinStream:subscribe(function(result)
	local leftRecord = result:get("luaEventLeft")
	local rightRecord = result:get("luaEventRight")
	print(("[%5.2f] [OUTER] left=%s right=%s"):format(
		scheduler.currentTime,
		formatEntry(leftRecord),
		formatEntry(rightRecord)
	))
end, function(err)
	io.stderr:write(("Outer join error: %s\n"):format(err))
end, function()
	print(("[%5.2f] Outer join completed"):format(scheduler.currentTime))
end)

local outerExpiredSubscription = outerExpired:subscribe(function(packet)
	describeExpired("OUTER", packet)
end, function(err)
	io.stderr:write(("Outer expired error: %s\n"):format(err))
end, function()
	print(("[%5.2f] Outer expired completed"):format(scheduler.currentTime))
end)

local antiOuterSubscription = antiOuterJoinStream:subscribe(function(result)
	local leftRecord = result:get("luaEventLeft")
	local rightRecord = result:get("luaEventRight")
	print(("[%5.2f] [ANTI] left=%s right=%s"):format(
		scheduler.currentTime,
		formatEntry(leftRecord),
		formatEntry(rightRecord)
	))
end, function(err)
	io.stderr:write(("Anti outer join error: %s\n"):format(err))
end, function()
	print(("[%5.2f] Anti outer join completed"):format(scheduler.currentTime))
end)

local antiExpiredSubscription = antiExpired:subscribe(function(packet)
	describeExpired("ANTI", packet)
end, function(err)
	io.stderr:write(("Anti expired error: %s\n"):format(err))
end, function()
	print(("[%5.2f] Anti expired completed"):format(scheduler.currentTime))
end)

while not scheduler:isEmpty() do
	scheduler:update(TIMER_RESOLUTION)
	sleep(TIMER_RESOLUTION)
end

innerSubscription:unsubscribe()
outerSubscription:unsubscribe()
antiOuterSubscription:unsubscribe()
outerExpiredSubscription:unsubscribe()
antiExpiredSubscription:unsubscribe()
