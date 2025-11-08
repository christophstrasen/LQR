require("bootstrap")

local JoinObservable = require("JoinObservable.init")
local Schema = require("JoinObservable.schema")
local rx = require("reactivex")

local customers = require("viz_low_level.scenarios.left_join.customers")
local orders = require("viz_low_level.scenarios.left_join.orders")

local function prepareRecords(source, opts)
	opts = opts or {}
	local current = opts.startTime or 1
	local step = opts.step or 1
	local prepared = {}

	for _, record in ipairs(source) do
		local copy = {}
		for k, v in pairs(record) do
			copy[k] = v
		end
		copy.sourceTime = current
		current = current + step
		prepared[#prepared + 1] = copy
	end

	return prepared
end

local function throttle(records, opts)
	opts = opts or {}
	local minDelay = opts.minDelay or 0.01
	local maxDelay = opts.maxDelay or minDelay
	local mode = opts.mode or "ordered" -- "ordered" or "jittered"
	local hasDelay = (minDelay > 0) or (maxDelay > 0)
	local sleeper = function(seconds)
		if not seconds or seconds <= 0 then
			return
		end
		local target = os.clock() + seconds
		while os.clock() < target do
		end
	end

	local function delayForIndex(index)
		if mode == "jittered" then
			return minDelay + math.random() * (maxDelay - minDelay)
		end
		return minDelay
	end

	if not hasDelay then
		-- Fast path: no throttling requested.
		return rx.Observable.fromTable(records, ipairs, true)
	end

	return rx.Observable.create(function(observer)
		for index, record in ipairs(records) do
			sleeper(delayForIndex(index))
			observer:onNext(record)
		end
		observer:onCompleted()
	end)
end

local function createStream(schemaName, source, opts)
	opts = opts or {}
	local prepared = prepareRecords(source, { startTime = opts.startTime or 1, step = opts.step or 1 })
	local wrapOpts = opts.wrapOpts or {}

	if opts.idField then
		wrapOpts.idField = opts.idField
	end

	return Schema.wrap(schemaName, throttle(prepared, opts.throttle), wrapOpts)
end

-- Use simple ascending timestamps so ordering is deterministic in this experiment.
local customersStream = createStream("customers", customers, {
	step = 10,
	throttle = { minDelay = 0.005, maxDelay = 0.015, mode = "ordered" },
})

local ordersStream = createStream("orders", orders, {
	step = 5,
	idField = "orderId",
	throttle = { minDelay = 0.005, maxDelay = 0.015, mode = "jittered" },
})

local joinStream = JoinObservable.createJoinObservable(customersStream, ordersStream, {
	on = {
		customers = "id",
		orders = "customerId",
	},
	joinType = "anti_left",
	joinWindow = {
		-- Time-based retention like the viz scenario; TTL is generous so nothing
		-- evaporates during the demo run, but the join window is driven by sourceTime.
		mode = "time",
		ttl = 4,
		field = "sourceTime",
		currentFn = os.clock,
	},
})

print("[LEFT JOIN] customers ~ orders (ordered timestamps)")
joinStream:subscribe(function(result)
	local customer = result:get("customers")
	local order = result:get("orders")

	if customer and order then
		print(
			("[JOINED] customer=%s (id=%s, t=%s) orderId=%s total=%s"):format(
				customer.name,
				customer.id,
				tostring(customer.sourceTime or (customer.RxMeta and customer.RxMeta.sourceTime)),
				order.orderId or order.id,
				order.total
			)
		)
	elseif customer then
		print(
			("[UNMATCHED] customer=%s (id=%s, t=%s) no orders"):format(
				customer.name,
				customer.id,
				tostring(customer.sourceTime or (customer.RxMeta and customer.RxMeta.sourceTime))
			)
		)
	end
end, function(err)
	io.stderr:write(("[ERROR] %s\n"):format(tostring(err)))
end, function()
	print("[COMPLETE] join finished")
end)
