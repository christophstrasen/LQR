-- order_queue.lua -- queue + index map for stable FIFO eviction without relying on `#table`.
local OrderQueue = {}

local function isOrderQueue(order)
	return type(order) == "table"
		and type(order.entries) == "table"
		and type(order.indexByRecord) == "table"
		and type(order.head) == "number"
		and type(order.tail) == "number"
		and type(order.count) == "number"
end

function OrderQueue.isOrderQueue(order)
	return isOrderQueue(order)
end

function OrderQueue.new()
	return {
		entries = {},
		indexByRecord = {},
		head = 1,
		tail = 0,
		count = 0,
	}
end

function OrderQueue.clear(order)
	if not isOrderQueue(order) then
		return
	end
	order.entries = {}
	order.indexByRecord = {}
	order.head = 1
	order.tail = 0
	order.count = 0
end

local function compactIfNeeded(order)
	if order.head <= 128 then
		return
	end
	if order.head <= (order.tail / 2) then
		return
	end

	local newEntries = {}
	local newTail = 0
	local newIndex = {}
	for i = order.head, order.tail do
		local entry = order.entries[i]
		if entry ~= nil then
			newTail = newTail + 1
			newEntries[newTail] = entry
			if entry.record ~= nil then
				newIndex[entry.record] = newTail
			end
		end
	end
	order.entries = newEntries
	order.indexByRecord = newIndex
	order.head = 1
	order.tail = newTail
end

function OrderQueue.push(order, key, record)
	if not isOrderQueue(order) then
		return nil
	end
	order.tail = order.tail + 1
	local entry = { key = key, record = record }
	order.entries[order.tail] = entry
	order.count = order.count + 1
	if record ~= nil then
		order.indexByRecord[record] = order.tail
	end
	return entry
end

function OrderQueue.removeRecord(order, record)
	if not isOrderQueue(order) or record == nil then
		return false
	end
	local idx = order.indexByRecord[record]
	if idx == nil then
		return false
	end
	order.entries[idx] = nil
	order.indexByRecord[record] = nil
	order.count = math.max(0, order.count - 1)
	return true
end

function OrderQueue.pop(order)
	if not isOrderQueue(order) then
		return nil
	end
	local head = order.head
	while head <= order.tail and order.entries[head] == nil do
		head = head + 1
	end
	order.head = head
	if head > order.tail then
		return nil
	end
	local entry = order.entries[head]
	order.entries[head] = nil
	order.head = head + 1
	order.count = math.max(0, order.count - 1)
	if entry and entry.record ~= nil then
		order.indexByRecord[entry.record] = nil
	end
	compactIfNeeded(order)
	return entry
end

return OrderQueue

