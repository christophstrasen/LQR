require("bootstrap")

local rx = require("reactivex")
local io = require("io")

math.randomseed(os.time())

local scheduler = rx.CooperativeScheduler.create()
local TIMER_RESOLUTION = 0.05 -- seconds per update tick

local function sleep(seconds)
	local start = os.clock()
	while (os.clock() - start) < seconds do
		-- busy-wait to simulate wall-clock delay for the virtual scheduler
	end
end

local function logValue(label, value)
	print(("[%5.2f] [%s] emit -> %d"):format(scheduler.currentTime, label, value))
end

local function createInputTable(size, minValue, maxValue)
	local values = {}
	for i = 1, size do
		values[i] = math.random(minValue, maxValue)
	end
	return values
end

local function describeTable(label, values)
	print(("[%s] source values: %s"):format(label, table.concat(values, ", ")))
end

local function streamFromTable(label, values)
	return rx.Observable.create(function(observer)
		local cancelled = false

		local function producer()
			for _, value in ipairs(values) do
				if cancelled or observer.stopped then
					return
				end

				logValue(label, value)
				observer:onNext(value)
				coroutine.yield(math.random(100, 900) / 10000)
				-- coroutine.yield(0.2)
			end

			print(("[%5.2f] [%s] source completed"):format(scheduler.currentTime, label))
			observer:onCompleted()
		end

		local task = scheduler:schedule(producer)

		return function()
			cancelled = true
			if task and not task:isUnsubscribed() then
				task:unsubscribe()
			end
		end
	end)
end

local leftValues = createInputTable(20, 1, 10)
local rightValues = createInputTable(20, 1, 10)

describeTable("LEFT", leftValues)
describeTable("RIGHT", rightValues)

local leftStream = streamFromTable("LEFT", leftValues)
local rightStream = streamFromTable("RIGHT", rightValues)

local matchedStream = leftStream
	:combineLatest(rightStream, function(left, right)
		return left, right
	end)
	:filter(function(left, right)
		return left % 2 == 1 and right % 2 == 1
	end)

local subscription = matchedStream:subscribe(function(left, right)
	print(("[%5.2f] [MATCH] left=%d | right=%d"):format(scheduler.currentTime, left, right))
end, function(err)
	io.stderr:write(("combineLatest error: %s\n"):format(err))
end, function()
	print(("[%5.2f] [MATCH] stream completed"):format(scheduler.currentTime))
end)

while not scheduler:isEmpty() do
	scheduler:update(TIMER_RESOLUTION)
	sleep(TIMER_RESOLUTION)
end

subscription:unsubscribe()
