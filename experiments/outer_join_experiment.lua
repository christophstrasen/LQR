require("bootstrap")

local JoinObservable = require("JoinObservable.init")
local Schema = require("JoinObservable.schema")
local rx = require("reactivex")

local customers = {
	{ id = 101, name = "Ada" },
	{ id = 102, name = "Ben" },
	{ id = 103, name = "Cara" },
	{ id = 104, name = "Drew" },
}

local orders = {
	{ orderId = 2001, customerId = 101, total = 200 },
	{ orderId = 2002, customerId = 999, total = 125 }, -- no matching customer
	{ orderId = 2003, customerId = 103, total = 80 },
	{ orderId = 2004, customerId = 888, total = 280 }, -- no matching customer
}

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

local customersStream = createStream("customers", customers, {
	step = 8,
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
	joinType = "outer",
	joinWindow = {
		mode = "time",
		ttl = 4,
		field = "sourceTime",
		currentFn = os.clock,
	},
})

print("[OUTER JOIN] customers ~ orders (ordered timestamps)")
joinStream:subscribe(function(result)
	local customer = result:get("customers")
	local order = result:get("orders")

	if customer and order then
		print(
			("[MATCHED] customer=%s (id=%s, t=%s) orderId=%s total=%s"):format(
				customer.name,
				customer.id,
				tostring(customer.sourceTime or (customer.RxMeta and customer.RxMeta.sourceTime)),
				order.orderId or order.id,
				order.total
			)
		)
	elseif customer then
		print(
			("[UNMATCHED LEFT] customer=%s (id=%s, t=%s) no orders"):format(
				customer.name,
				customer.id,
				tostring(customer.sourceTime or (customer.RxMeta and customer.RxMeta.sourceTime))
			)
		)
	elseif order then
		print(
			("[UNMATCHED RIGHT] orderId=%s (customerId=%s, t=%s) total=%s no customer"):format(
				order.orderId or order.id,
				order.customerId,
				tostring(order.sourceTime or (order.RxMeta and order.RxMeta.sourceTime)),
				order.total
			)
		)
	end
end, function(err)
	io.stderr:write(("[ERROR] %s\n"):format(tostring(err)))
end, function()
	print("[COMPLETE] outer join finished")
end)
