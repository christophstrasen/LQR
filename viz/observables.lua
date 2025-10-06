local rx = require("reactivex")
local Schema = require("JoinObservable.schema")
local JoinObservable = require("JoinObservable")

local Data = require("viz.source_data")
local Delay = require("viz.observable_delay")

local Observables = {}

local function emitRecords(records)
	records = records or {}
	return rx.Observable.create(function(observer)
		local cancelled = false
		local index = 1

		local function emitNext()
			if cancelled then
				return
			end
			local record = records[index]
			if not record then
				observer:onCompleted()
				return
			end
			observer:onNext(record)
			index = index + 1
			rx.scheduler.schedule(emitNext, 0)
		end

		rx.scheduler.schedule(emitNext, 0)

		return function()
			cancelled = true
		end
	end)
end

local function buildStream(records, schemaName, idField, delayOpts)
	local stream = emitRecords(records)
	if delayOpts then
		stream = Delay.withDelay(stream, delayOpts)
	end
	return Schema.wrap(schemaName, stream, { idField = idField or "id" })
end

Observables.customers = buildStream(Data.customers, "customers", "id", Data.streamDelays.customers)
Observables.orders = buildStream(Data.orders, "orders", "orderId", Data.streamDelays.orders)

local join, expired = JoinObservable.createJoinObservable(Observables.customers, Observables.orders, {
	on = {
		customers = "id",
		orders = "customerId",
	},
	joinType = "left",
	expirationWindow = Data.expirationWindow,
})

local function shapeJoinRecord(result)
	if not result then
		return nil
	end
	local customer = result:get("customers")
	local order = result:get("orders")
	if not customer and not order then
		return nil
	end
	local id = customer and customer.id or order and order.customerId or nil
	if not id then
		return nil
	end
	local label
	if customer and order then
		label = string.format("%s + order %s", customer.name or customer.id, order.orderId)
	elseif customer then
		label = string.format("%s (no order)", customer.name or customer.id)
	else
		label = string.format("order %s (no customer)", order.orderId)
	end
	return {
		id = id,
		label = label,
		match = customer ~= nil and order ~= nil,
		customer = customer,
		order = order,
		schema = "joined",
		schemas = {
			customers = customer,
			orders = order,
		},
	}
end

local function shapeExpiredRecord(packet)
	if not packet then
		return nil
	end
	local schemaName = packet.schema
	local result = packet.result
	local record
	if result then
		if schemaName then
			record = result:get(schemaName)
		else
			local names = result:schemaNames()
			for _, name in ipairs(names) do
				record = result:get(name)
				if record then
					schemaName = name
					break
				end
			end
		end
	end
	schemaName = schemaName or "expired"
	if not record then
		return nil
	end
	local id
	if schemaName == "orders" and record.customerId then
		id = record.customerId
	else
		id = record.id or (record.RxMeta and record.RxMeta.id)
	end
	if not id then
		return nil
	end
	return {
		id = id,
		schema = schemaName,
		record = record,
		reason = packet.reason,
		expired = true,
		schemas = {
			[schemaName] = record,
		},
	}
end

Observables.customersWithOrders = join:map(shapeJoinRecord):filter(function(record)
	return record ~= nil
end)

if expired then
	Observables.expired = expired:map(shapeExpiredRecord):filter(function(record)
		return record ~= nil
	end)
else
	Observables.expired = rx.Observable.create(function(observer)
		observer:onCompleted()
	end)
end

return Observables
