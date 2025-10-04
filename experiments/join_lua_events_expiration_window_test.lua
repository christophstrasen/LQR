require("bootstrap")

local rx = require("reactivex")
local LuaEvent = require("Starlit.LuaEvent")
local JoinObservable = require("JoinObservable")
local Schema = require("JoinObservable.schema")
local io = require("io")

local scheduler = rx.CooperativeScheduler.create()
local TIMER_RESOLUTION = 0.05

local function sleep(seconds)
	local start = os.clock()
	while (os.clock() - start) < seconds do
	end
end

local function printPair(label, result)
	local left = result:get("luaIntervalLeft")
	local right = result:get("luaIntervalRight")
	print(("[%5.2f] [%s] left=%s right=%s"):format(
		scheduler.currentTime,
		label,
		left and ("id=" .. left.id .. ",ts=" .. left.ts) or "nil",
		right and ("id=" .. right.id .. ",ts=" .. right.ts) or "nil"
	))
end

local function printExpired(label, packet)
	local alias = packet.alias or "unknown"
	local entry = packet.result and packet.result:get(alias)
	print(("[%5.2f] [%s expired] alias=%s key=%s reason=%s entry=%s"):format(
		scheduler.currentTime,
		label,
		alias,
		tostring(packet.key),
		packet.reason or "n/a",
		entry and ("id=" .. tostring(entry.id) .. ",ts=" .. tostring(entry.ts)) or "nil"
	))
end

local function createEntries(schema, timestamps)
	local entries = {}
	for i, ts in ipairs(timestamps) do
		table.insert(entries, {
			schema = schema,
			id = i,
			ts = ts,
			keep = (i % 2 == 0),
		})
	end
	return entries
end

local function scheduleEmitter(label, event, entries)
	scheduler:schedule(function()
		for _, entry in ipairs(entries) do
			print(("[%5.2f] [%s seed] id=%d ts=%d keep=%s"):format(
				scheduler.currentTime,
				label,
				entry.id,
				entry.ts,
				tostring(entry.keep)
			))
			event:trigger(entry)
			coroutine.yield(TIMER_RESOLUTION)
		end
		print(("[%5.2f] [%s seed] completed"):format(scheduler.currentTime, label))
	end)
end

local leftEvent = LuaEvent.new()
local rightEvent = LuaEvent.new()

local leftEntries = createEntries("left", { 0, 2, 4, 6, 8 })
local rightEntries = createEntries("right", { 1, 3, 5, 7, 9 })

scheduleEmitter("LEFT", leftEvent, leftEntries)
scheduleEmitter("RIGHT", rightEvent, rightEntries)

local leftStream = Schema.wrap("luaIntervalLeft", rx.Observable.fromLuaEvent(leftEvent):take(#leftEntries))
local rightStream = Schema.wrap("luaIntervalRight", rx.Observable.fromLuaEvent(rightEvent):take(#rightEntries))

local function collect(label, stream)
	return stream:subscribe(function(value)
		printPair(label, value)
	end, function(err)
		io.stderr:write(("[%s] error: %s\n"):format(label, err))
	end, function()
		print(("[%5.2f] [%s] completed"):format(scheduler.currentTime, label))
	end)
end

local function collectExpired(label, expiredStream)
	return expiredStream:subscribe(function(packet)
		printExpired(label, packet)
	end, function(err)
		io.stderr:write(("[%s expired] error: %s\n"):format(label, err))
	end, function()
		print(("[%5.2f] [%s expired] completed"):format(scheduler.currentTime, label))
	end)
end

local function makeJoin(name, options)
	local stream, expired = JoinObservable.createJoinObservable(leftStream, rightStream, options)
	return collect(name, stream), collectExpired(name, expired)
end

local countJoin, countExpired = makeJoin("COUNT", {
	on = "id",
	joinType = "outer",
	expirationWindow = {
		mode = "count",
		maxItems = 2,
	},
})

local currentTime = 0
local intervalJoin, intervalExpired = makeJoin("INTERVAL", {
	on = "id",
	joinType = "outer",
	expirationWindow = {
		mode = "interval",
		field = "ts",
		offset = 3,
		currentFn = function()
			return currentTime
		end,
	},
})

local predicateJoin, predicateExpired = makeJoin("PREDICATE", {
	on = "id",
	joinType = "outer",
	expirationWindow = {
		mode = "predicate",
		predicate = function(entry)
			return entry.keep
		end,
		currentFn = function()
			return scheduler.currentTime
		end,
	},
})

local timeJoin, timeExpired = makeJoin("TIME", {
	on = "id",
	joinType = "outer",
	expirationWindow = {
		mode = "time",
		field = "ts",
		ttl = 3,
		currentFn = function()
			return scheduler.currentTime
		end,
	},
})

local splitJoin, splitExpired = makeJoin("SPLIT", {
	on = "id",
	joinType = "outer",
	expirationWindow = {
		left = {
			mode = "count",
			maxItems = 1,
		},
		right = {
			mode = "time",
			field = "ts",
			ttl = 2,
			currentFn = function()
				return scheduler.currentTime
			end,
		},
	},
})

while not scheduler:isEmpty() do
	currentTime = scheduler.currentTime
	scheduler:update(TIMER_RESOLUTION)
	sleep(TIMER_RESOLUTION)
end

countJoin:unsubscribe()
countExpired:unsubscribe()
intervalJoin:unsubscribe()
intervalExpired:unsubscribe()
predicateJoin:unsubscribe()
predicateExpired:unsubscribe()
timeJoin:unsubscribe()
timeExpired:unsubscribe()
splitJoin:unsubscribe()
splitExpired:unsubscribe()
