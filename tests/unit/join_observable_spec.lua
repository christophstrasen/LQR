local package = require("package")
package.path = "./?.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require('LQR/bootstrap')

local rx = require("reactivex")
local JoinObservable = require("LQR/JoinObservable")
local SchemaHelpers = require("tests/support/schema_helpers")
local Result = require("LQR/JoinObservable/result")

local Schema = require("LQR/JoinObservable/schema")
local Log = require("LQR/util/log")

local function collectValues(observable)
	local results = {}
	local completed = false
	local errorMessage

	observable:subscribe(function(value)
		table.insert(results, value)
	end, function(err)
		errorMessage = err
	end, function()
		completed = true
	end)

	return results, completed, errorMessage
end

local function summarizePairs(pairs)
	local summary = {}
	for _, pair in ipairs(pairs) do
		local leftRecord = pair:get("left")
		local rightRecord = pair:get("right")
		local leftId = leftRecord and leftRecord.id or nil
		local rightId = rightRecord and rightRecord.id or nil
		table.insert(summary, { left = leftId, right = rightId })
	end

	table.sort(summary, function(a, b)
		local leftA = a.left or math.huge
		local leftB = b.left or math.huge
		if leftA == leftB then
			local rightA = a.right or math.huge
			local rightB = b.right or math.huge
			return rightA < rightB
		end
		return leftA < leftB
	end)

	return summary
end

local function withCapturedWarnings(fn)
	local captured = {}
	local previous = Log.setEmitter(function(level, message, tag)
		if level == "warn" and (not tag or tag == "join") then
			table.insert(captured, message)
		end
	end)
	local ok, err = pcall(fn, captured)
	Log.setEmitter(previous)
	if not ok then
		error(err)
	end
	return captured
end

local function expiredEntry(packet)
	if not packet then
		return nil, nil
	end
	local schemaName = packet.schema or "unknown"
	local entry = packet.result and packet.result:get(schemaName)
	return entry, schemaName
end

local ordersCustomersOn = {
	orders = "customerId",
	customers = { field = "id" },
}

---@diagnostic disable: undefined-global
---@diagnostic disable: undefined-field
describe("JoinObservable", function()
	after_each(function()
		Log.setEmitter()
	end)

	describe("JoinResult helper", function()
	local function buildResult()
			local customer = {
				id = 1,
				name = "Ada",
				RxMeta = { schema = "customers", schemaVersion = 2, joinKey = "1", sourceTime = 100 },
			}
			local order = {
				id = 100,
				customerId = 1,
				RxMeta = { schema = "orders", joinKey = "1", sourceTime = 120 },
			}

			local result = Result.new():attach("customers", customer):attach("orders", order)
			return result
		end

		it("attaches schemas and preserves metadata", function()
			local result = buildResult()

			assert.is_not_nil(result:get("customers"))
			assert.is_not_nil(result:get("orders"))
			assert.are.same({ "customers", "orders" }, result:schemaNames())
		end)

		it("clones schema payloads without mutating the source", function()
			local result = buildResult()
			local clone = result:clone()

			assert.are_not.equal(result:get("orders"), clone:get("orders"))
			clone:get("orders").customerId = 999
			assert.are.equal(1, result:get("orders").customerId)
		end)

		it("selects and renames schema names", function()
			local result = buildResult()
			local renamed = Result.selectSchemas(result, { customers = "buyer" })
			local buyer = renamed:get("buyer")

			assert.is_not_nil(buyer)
			assert.are.equal("buyer", buyer.RxMeta.schema)
		end)

		it("attaches from another result", function()
			local source = buildResult()
			local target = Result.new()
			target:attachFrom(source, "orders", "forwarded_orders")
			local forwarded = target:get("forwarded_orders")
			assert.is_not_nil(forwarded)
			assert.are.equal("forwarded_orders", forwarded.RxMeta.schema)
		end)
	end)

describe("Schema.wrap subject chaining", function()
	it("allows re-emitting wrapped records into new streams", function()
		local sourceSubject = rx.Subject.create()
		local bufferSubject = rx.Subject.create()
		local firstWrapped = Schema.wrap("orders", sourceSubject, { idField = "id" })
		local secondWrapped = Schema.wrap("orders", bufferSubject, { idField = "id" })

			local firstCaptured, secondCaptured = {}, {}

			local firstSubscription = firstWrapped:subscribe(function(record)
				table.insert(firstCaptured, record)
				bufferSubject:onNext(record)
			end)

			local secondSubscription = secondWrapped:subscribe(function(record)
				table.insert(secondCaptured, record)
			end)

			sourceSubject:onNext({ id = 1, total = 50 })
			sourceSubject:onNext({ id = 2, total = 75 })
			sourceSubject:onCompleted()
			bufferSubject:onCompleted()

			assert.are.equal(2, #firstCaptured)
			assert.are.equal(2, #secondCaptured)
			for i = 1, 2 do
				assert.are.equal(firstCaptured[i], secondCaptured[i])
				assert.are.equal("orders", firstCaptured[i].RxMeta.schema)
				assert.are.equal("orders", secondCaptured[i].RxMeta.schema)
			end

			firstSubscription:unsubscribe()
		secondSubscription:unsubscribe()
	end)
end)

describe("Schema.wrap id enforcement", function()
	it("derives ids from configured fields", function()
		local subject = rx.Subject.create()
		local wrapped = Schema.wrap("events", subject, { idField = "uuid" })
		local seen = {}
		wrapped:subscribe(function(record)
			table.insert(seen, record)
		end)

		subject:onNext({ uuid = "abc-1", payload = "ok" })
		subject:onCompleted()

		assert.are.equal(1, #seen)
		assert.are.equal("abc-1", seen[1].RxMeta.id)
		assert.are.equal("uuid", seen[1].RxMeta.idField)
	end)

	it("drops records missing the configured id field", function()
		local subject = rx.Subject.create()
		local wrapped = Schema.wrap("events", subject, { idField = "uuid" })
		local seen = {}
		local warningsRaised = withCapturedWarnings(function(captured)
			warningsRaised = captured
			wrapped:subscribe(function(record)
				table.insert(seen, record)
			end)

			subject:onNext({ payload = "missing" }) -- dropped
			subject:onNext({ uuid = "present" })
			subject:onCompleted()
		end)

		assert.are.equal(1, #seen)
		assert.are.equal("present", seen[1].RxMeta.id)
		assert.is_true(#warningsRaised >= 1)
	end)

	it("derives ids via selectors", function()
		local subject = rx.Subject.create()
		local wrapped = Schema.wrap("events", subject, {
			idSelector = function(entry)
				return (entry.partition or "?") .. ":" .. tostring(entry.localId)
			end,
		})
		local seen = {}
		wrapped:subscribe(function(record)
			table.insert(seen, record)
		end)

		subject:onNext({ partition = "alpha", localId = 42 })
		subject:onCompleted()

		assert.are.equal(1, #seen)
		assert.are.equal("alpha:42", seen[1].RxMeta.id)
	end)
end)

	it("emits only matched pairs for an inner join", function()
		local left = SchemaHelpers.observableFromTable("left", {
			{ schema = "left", id = 1 },
			{ schema = "left", id = 2 },
		})

		local right = SchemaHelpers.observableFromTable("right", {
			{ schema = "right", id = 2 },
			{ schema = "right", id = 3 },
		})

		local innerJoin = JoinObservable.createJoinObservable(left, right, {
			on = "id",
			joinType = "inner",
			maxCacheSize = 10,
		})

		local pairs, completed, err = collectValues(innerJoin)

		assert.is_nil(err)
		assert.is_true(completed)
		assert.are.same({
			{ left = 2, right = 2 },
		}, summarizePairs(pairs))
	end)

	it("defaults to an inner join keyed by id when options are omitted", function()
		local left = SchemaHelpers.observableFromTable("left", {
			{ schema = "left", id = 10 },
			{ schema = "left", id = 20 },
		})

		local right = SchemaHelpers.observableFromTable("right", {
			{ schema = "right", id = 20 },
			{ schema = "right", id = 30 },
		})

		local defaultJoin = JoinObservable.createJoinObservable(left, right)
		local pairs, completed, err = collectValues(defaultJoin)

		assert.is_nil(err)
		assert.is_true(completed)
		assert.are.same({
			{ left = 20, right = 20 },
		}, summarizePairs(pairs))
	end)

	it("matches asymmetric key fields when the selector inspects schema metadata", function()
		local orders = SchemaHelpers.observableFromTable("orders", {
			{ orderId = 101, customerId = 1, total = 50 },
			{ orderId = 102, customerId = 2, total = 75 },
		}, { idField = "orderId" })

		local customers = SchemaHelpers.observableFromTable("customers", {
			{ id = 1, name = "Ada" },
			{ id = 2, name = "Bela" },
		})

		local join = JoinObservable.createJoinObservable(orders, customers, {
			on = ordersCustomersOn,
			joinType = "inner",
		})

		local results, completed, err = collectValues(join)
		assert.is_nil(err)
		assert.is_true(completed)
		assert.are.equal(2, #results)

		local summary = {}
		for _, pair in ipairs(results) do
			local order = pair:get("orders")
			local customer = pair:get("customers")
			assert.is_not_nil(order)
			assert.is_not_nil(customer)
			table.insert(summary, {
				orderId = order.orderId,
				customerId = order.customerId,
				customerName = customer.name,
				orderKey = order.RxMeta and order.RxMeta.joinKey,
				customerKey = customer.RxMeta and customer.RxMeta.joinKey,
			})
		end

		table.sort(summary, function(a, b)
			return a.orderId < b.orderId
		end)

		assert.are.same({
			{
				orderId = 101,
				customerId = 1,
				customerName = "Ada",
				orderKey = 1,
				customerKey = 1,
			},
			{
				orderId = 102,
				customerId = 2,
				customerName = "Bela",
				orderKey = 2,
				customerKey = 2,
			},
		}, summary)
	end)

	it("evicts unmatched asymmetric rows without dropping schema metadata", function()
		local orderSubject, orders = SchemaHelpers.subjectWithSchema("orders", { idField = "orderId" })
		local customerSubject, customers = SchemaHelpers.subjectWithSchema("customers")

		local join, expired = JoinObservable.createJoinObservable(orders, customers, {
			on = ordersCustomersOn,
			joinType = "left",
			maxCacheSize = 1,
		})

		local emissions = {}
		local joinSubscription = join:subscribe(function(result)
			table.insert(emissions, result)
		end)

		local expiredPackets = {}
		local expiredSubscription = expired:subscribe(function(packet)
			table.insert(expiredPackets, packet)
		end)

		orderSubject:onNext({ orderId = 400, customerId = 10 })
		orderSubject:onNext({ orderId = 401, customerId = 11 })
		customerSubject:onNext({ id = 11, name = "Helen" })

		orderSubject:onCompleted()
		customerSubject:onCompleted()

		joinSubscription:unsubscribe()
		expiredSubscription:unsubscribe()

		assert.are.equal(2, #emissions)

		local evictedOrder = emissions[1]:get("orders")
		assert.is_not_nil(evictedOrder)
		assert.is_nil(emissions[1]:get("customers"))
		assert.are.equal(400, evictedOrder.orderId)
		assert.are.equal(10, evictedOrder.customerId)
		assert.are.equal(10, evictedOrder.RxMeta and evictedOrder.RxMeta.joinKey)

		local matchedOrder = emissions[2]:get("orders")
		assert.is_not_nil(matchedOrder)
		assert.are.equal(401, matchedOrder.orderId)
		assert.are.equal(11, matchedOrder.customerId)

		assert.is_true(#expiredPackets >= 1)
	end)

	it("surfaces expired records via the secondary observable", function()
		local left = SchemaHelpers.observableFromTable("left", {
			{ schema = "left", id = 1 },
			{ schema = "left", id = 2 },
		})

		local right = SchemaHelpers.observableFromTable("right", {
			{ schema = "right", id = 3 },
		})

		local antiOuter, expired = JoinObservable.createJoinObservable(left, right, {
			on = "id",
			joinType = "anti_outer",
			maxCacheSize = 10,
		})

		local expiredEvents = {}
		expired:subscribe(function(record)
			table.insert(expiredEvents, record)
		end)

		local pairs = {}
		antiOuter:subscribe(function(value)
			table.insert(pairs, value)
		end)

		local pairSummary = summarizePairs(pairs)
		assert.are.same({
			{ left = 1, right = nil },
			{ left = 2, right = nil },
			{ left = nil, right = 3 },
		}, pairSummary)

		assert.are.same(3, #expiredEvents)
		local expiredIds = {}
		for _, packet in ipairs(expiredEvents) do
			local entry, schemaName = expiredEntry(packet)
			if entry then
				expiredIds[entry.id] = schemaName
			end
		end
		assert.are.same({
			[1] = "left",
			[2] = "left",
			[3] = "right",
		}, expiredIds)
	end)

	it("evicts the oldest cached entries when the cache exceeds the cap", function()
		local leftSubject, left = SchemaHelpers.subjectWithSchema("left")
		local rightSubject, right = SchemaHelpers.subjectWithSchema("right")

		local innerJoin, expired = JoinObservable.createJoinObservable(left, right, {
			on = "id",
			joinType = "inner",
			maxCacheSize = 1,
		})

		local pairs = {}
		innerJoin:subscribe(function(value)
			table.insert(pairs, value)
		end)

		local expiredEvents = {}
		expired:subscribe(function(record)
			table.insert(expiredEvents, record)
		end)

		leftSubject:onNext({ schema = "left", id = 1 })
		leftSubject:onNext({ schema = "left", id = 2 })
		leftSubject:onNext({ schema = "left", id = 3 })

		rightSubject:onNext({ schema = "right", id = 1 })
		rightSubject:onNext({ schema = "right", id = 2 })
		rightSubject:onNext({ schema = "right", id = 3 })

		leftSubject:onCompleted()
		rightSubject:onCompleted()

			assert.are.same({
				{
					left = 3,
					right = 3,
				},
			}, summarizePairs(pairs))

		local leftExpired = {}
		for _, packet in ipairs(expiredEvents) do
			if packet.schema == "left" then
				table.insert(leftExpired, packet)
			end
		end

		assert.are.same(3, #leftExpired)
			assert.are.same({ "evicted", "evicted", "completed" }, {
				leftExpired[1].reason,
				leftExpired[2].reason,
				leftExpired[3].reason,
			})
		local entryOne = expiredEntry(leftExpired[1])
		local entryTwo = expiredEntry(leftExpired[2])
		local entryThree = expiredEntry(leftExpired[3])
		assert.are.same({ 1, 2, 3 }, { entryOne and entryOne.id, entryTwo and entryTwo.id, entryThree and entryThree.id })
	end)

	it("only keeps the newest key available for future matches when entries are evicted", function()
		local leftSubject, left = SchemaHelpers.subjectWithSchema("left")
		local rightSubject, right = SchemaHelpers.subjectWithSchema("right")

		local join, expired = JoinObservable.createJoinObservable(left, right, {
			on = "id",
			maxCacheSize = 1,
		})

		local pairs = {}
		join:subscribe(function(value)
			table.insert(pairs, value)
		end)

		local expiredEvents = {}
		expired:subscribe(function(record)
			table.insert(expiredEvents, record)
		end)

		leftSubject:onNext({ schema = "left", id = 1 })
		leftSubject:onNext({ schema = "left", id = 2 })
		leftSubject:onNext({ schema = "left", id = 3 })

			assert.is_true(#expiredEvents >= 2)
			assert.are.same({ "left", "left" }, {
				expiredEvents[1] and expiredEvents[1].schema or nil,
				expiredEvents[2] and expiredEvents[2].schema or nil,
			})
			assert.are.same({ "evicted", "evicted" }, {
				expiredEvents[1] and expiredEvents[1].reason or nil,
				expiredEvents[2] and expiredEvents[2].reason or nil,
			})
			local entryFirst = expiredEntry(expiredEvents[1])
			local entrySecond = expiredEntry(expiredEvents[2])
			assert.are.same({ 1, 2 }, {
				entryFirst and entryFirst.id,
				entrySecond and entrySecond.id,
			})

		rightSubject:onNext({ schema = "right", id = 1 })
		rightSubject:onNext({ schema = "right", id = 2 })
		rightSubject:onNext({ schema = "right", id = 3 })
		rightSubject:onCompleted()
		leftSubject:onCompleted()

			assert.are.same({
				{
					left = 3,
					right = 3,
				},
			}, summarizePairs(pairs))
	end)

	it("supports functional key selectors", function()
		local left = SchemaHelpers.observableFromTable("left", {
			{ schema = "left", partition = "alpha", localId = 1 },
			{ schema = "left", partition = "beta", localId = 1 },
		}, {
			idSelector = function(entry)
				return ("%s:%s"):format(entry.partition, entry.localId)
			end,
		})

		local right = SchemaHelpers.observableFromTable("right", {
			{ schema = "right", partition = "alpha", localId = 1 },
			{ schema = "right", partition = "beta", localId = 2 },
			{ schema = "right", partition = "beta", localId = 1 },
		}, {
			idSelector = function(entry)
				return ("%s:%s"):format(entry.partition, entry.localId)
			end,
		})

		local join = JoinObservable.createJoinObservable(left, right, {
			on = function(entry)
				return ("%s:%s"):format(entry.partition, entry.localId)
			end,
			joinType = "inner",
			maxCacheSize = 10,
		})

		local pairs, completed, err = collectValues(join)
		assert.is_nil(err)
		assert.is_true(completed)
		assert.are.same(2, #pairs)

		local matchedKeys = {}
		for _, pair in ipairs(pairs) do
			local leftRecord = pair:get("left")
			local rightRecord = pair:get("right")
			local leftKey = ("%s:%s"):format(leftRecord.partition, leftRecord.localId)
			local rightKey = ("%s:%s"):format(rightRecord.partition, rightRecord.localId)
			table.insert(matchedKeys, leftKey .. "|" .. rightKey)
		end
		table.sort(matchedKeys)

		assert.are.same({
			"alpha:1|alpha:1",
			"beta:1|beta:1",
		}, matchedKeys)
	end)

	it("expires matched records on completion", function()
		local leftSubject, left = SchemaHelpers.subjectWithSchema("left")
		local rightSubject, right = SchemaHelpers.subjectWithSchema("right")

		local join, expired = JoinObservable.createJoinObservable(left, right, {
			on = "id",
			joinType = "inner",
			maxCacheSize = 5,
		})

		local expiredEvents = {}
		expired:subscribe(function(record)
			table.insert(expiredEvents, record)
		end)

		local pairs = {}
		join:subscribe(function(pair)
			table.insert(pairs, pair)
		end)

		leftSubject:onNext({ schema = "left", id = 42 })
		rightSubject:onNext({ schema = "right", id = 42 })
		leftSubject:onCompleted()
		rightSubject:onCompleted()

		assert.are.same({
			{ left = 42, right = 42 },
		}, summarizePairs(pairs))
		local expiredSummaries = {}
		for _, packet in ipairs(expiredEvents) do
			local entry, schema = expiredEntry(packet)
			expiredSummaries[#expiredSummaries + 1] = {
				schema = schema,
				id = entry and entry.id or nil,
				reason = packet.reason,
			}
		end
		table.sort(expiredSummaries, function(a, b)
			return tostring(a.schema) < tostring(b.schema)
		end)
		assert.are.same({
			{ schema = "left", id = 42, reason = "completed" },
			{ schema = "right", id = 42, reason = "completed" },
		}, expiredSummaries)
	end)

	it("expires matched records when TTL elapses", function()
		local clock = 0
		local function now()
			return clock
		end

		local leftSubject, left = SchemaHelpers.subjectWithSchema("left")
		local rightSubject, right = SchemaHelpers.subjectWithSchema("right")

		local join, expired = JoinObservable.createJoinObservable(left, right, {
			on = "id",
			joinType = "inner",
			joinWindow = {
				mode = "interval",
				field = "sourceTime",
				offset = 1,
				currentFn = now,
			},
		})

		local expiredEvents = {}
		expired:subscribe(function(packet)
			expiredEvents[#expiredEvents + 1] = packet
		end)

		join:subscribe(function() end)

		leftSubject:onNext({ schema = "left", id = 1, sourceTime = 0 })
		rightSubject:onNext({ schema = "right", id = 1, sourceTime = 0 })

		clock = 2
		leftSubject:onNext({ schema = "left", id = 99, sourceTime = 2 })
		rightSubject:onNext({ schema = "right", id = 99, sourceTime = 2 })

		assert.are.equal(2, #expiredEvents)
		local summary = {}
		for _, packet in ipairs(expiredEvents) do
			local entry, schema = expiredEntry(packet)
			summary[#summary + 1] = { schema = schema, id = entry and entry.id or nil, reason = packet.reason }
		end
		table.sort(summary, function(a, b)
			return tostring(a.schema) < tostring(b.schema)
		end)
		assert.are.same({
			{ schema = "left", id = 1, reason = "expired_interval" },
			{ schema = "right", id = 1, reason = "expired_interval" },
		}, summary)
	end)

	it("ignores malformed records emitted by a custom merge observable", function()
		Log.setEmitter(function() end)

		local left = SchemaHelpers.observableFromTable("left", {
			{ schema = "left", id = 5 },
		})

		local right = SchemaHelpers.observableFromTable("right", {
			{ schema = "right", id = 5 },
		})

		local function noisyMerge(leftTagged, rightTagged)
			local merged = leftTagged:merge(rightTagged)
			return rx.Observable.create(function(observer)
				local subscription
				subscription = merged:subscribe(function(record)
					observer:onNext(record)
					observer:onNext("noise")
					observer:onNext(nil)
				end, function(err)
					observer:onError(err)
				end, function()
					observer:onCompleted()
				end)

				return function()
					if subscription then
						subscription:unsubscribe()
					end
				end
			end)
		end

		local join, expired = JoinObservable.createJoinObservable(left, right, {
			on = "id",
			merge = noisyMerge,
		})

		local expiredEvents = {}
		expired:subscribe(function(record)
			table.insert(expiredEvents, record)
		end)

		local pairs, completed, err = collectValues(join)

		assert.is_nil(err)
		assert.is_true(completed)
		assert.are.same({
			{ left = 5, right = 5 },
		}, summarizePairs(pairs))
		-- Matched rows now expire on completion.
		assert.are.equal(2, #expiredEvents)
		local summary = {}
		for _, packet in ipairs(expiredEvents) do
			local entry, schema = expiredEntry(packet)
			summary[#summary + 1] = {
				schema = schema,
				id = entry and entry.id or nil,
				reason = packet.reason,
				matched = packet.matched,
			}
		end
		table.sort(summary, function(a, b)
			return tostring(a.schema) < tostring(b.schema)
		end)
		assert.are.same({
			{ schema = "left", id = 5, reason = "completed", matched = true },
			{ schema = "right", id = 5, reason = "completed", matched = true },
		}, summary)
	end)

	it("propagates merge errors to both the result and expiration observables", function()
		local left = SchemaHelpers.observableFromTable("left", {
			{ schema = "left", id = 1 },
		})
		local right = SchemaHelpers.observableFromTable("right", {
			{ schema = "right", id = 1 },
		})

		local function failingMerge()
			return rx.Observable.create(function(observer)
				observer:onError("merge failed")
			end)
		end

		local join, expired = JoinObservable.createJoinObservable(left, right, {
			on = "id",
			merge = failingMerge,
		})

		local expiredError
		expired:subscribe(function() end, function(err)
			expiredError = err
		end)

		local _, completed, joinError = collectValues(join)

		assert.is_false(completed)
		assert.are.equal("merge failed", joinError)
		assert.are.equal("merge failed", expiredError)
	end)

	it("completes the expiration observable when the join subscription is disposed", function()
		local leftSubject, left = SchemaHelpers.subjectWithSchema("left")
		local rightSubject, right = SchemaHelpers.subjectWithSchema("right")

		local join, expired = JoinObservable.createJoinObservable(left, right, {
			on = "id",
		})

		local expiredCompletions = 0
		local expiredErrors = 0
		expired:subscribe(function() end, function()
			expiredErrors = expiredErrors + 1
		end, function()
			expiredCompletions = expiredCompletions + 1
		end)

		local subscription = join:subscribe(function() end)

		leftSubject:onNext({ schema = "left", id = 7 })

		assert.are.equal(0, expiredCompletions)

		subscription:unsubscribe()

		assert.are.equal(1, expiredCompletions)
		assert.are.equal(0, expiredErrors)

		-- Ensure no further completion occurs if we unsubscribe again or touch subjects.
		subscription:unsubscribe()
		leftSubject:onNext({ schema = "left", id = 8 })
		assert.are.equal(1, expiredCompletions)
	end)

	it("drops entries whose key selector returns nil", function()
		local previousEmitter = Log.setEmitter(function() end)

		local left = SchemaHelpers.observableFromTable("left", {
			{ schema = "left", id = 1 },
			{ schema = "left" }, -- missing id -> nil key
			{ schema = "left", id = 2 },
		})

		local right = SchemaHelpers.observableFromTable("right", {
			{ schema = "right", id = 1 },
			{ schema = "right", id = 2 },
		})

		local expiredEvents = {}

		local join, expired = JoinObservable.createJoinObservable(left, right, {
			on = "id",
			joinType = "inner",
		})

		expired:subscribe(function(record)
			table.insert(expiredEvents, record)
		end)

		local pairs, completed, err = collectValues(join)
		assert.is_nil(err)
		assert.is_true(completed)
		assert.are.same({
			{ left = 1, right = 1 },
			{ left = 2, right = 2 },
		}, summarizePairs(pairs))

		assert.are.equal(4, #expiredEvents)
		for _, packet in ipairs(expiredEvents) do
			assert.are.equal("completed", packet.reason)
		end

		Log.setEmitter(previousEmitter)
	end)

	it("honors custom merge ordering and validates the merge contract", function()
		local left = SchemaHelpers.observableFromTable("left", {
			{ schema = "left", id = 1 },
		})

		local right = SchemaHelpers.observableFromTable("right", {
			{ schema = "right", id = 1 },
			{ schema = "right", id = 2 },
		})

		local forwardedOrder = {}
		local function orderedMerge(leftTagged, rightTagged)
			return rx.Observable.create(function(observer)
				local rightSub
				rightSub = rightTagged:subscribe(function(record)
					table.insert(forwardedOrder, record.side .. ":" .. record.entry.id)
					observer:onNext(record)
				end, function(err)
					observer:onError(err)
				end, function()
					leftTagged:subscribe(function(record)
						table.insert(forwardedOrder, record.side .. ":" .. record.entry.id)
						observer:onNext(record)
					end, function(err)
						observer:onError(err)
					end, function()
						observer:onCompleted()
					end)
				end)

				return function()
					if rightSub then
						rightSub:unsubscribe()
					end
				end
			end)
		end

		local join = JoinObservable.createJoinObservable(left, right, {
			on = "id",
			merge = orderedMerge,
		})

		local pairs, completed, err = collectValues(join)
		assert.is_nil(err)
		assert.is_true(completed)
		assert.are.same(1, #pairs)
		assert.are.same("right:1", forwardedOrder[1])
		assert.are.same("right:2", forwardedOrder[2])
		assert.are.same("left:1", forwardedOrder[3])

		local ok, failure = pcall(function()
			local invalidJoin = JoinObservable.createJoinObservable(left, right, {
				on = "id",
				merge = function()
					return {}
				end,
			})
			invalidJoin:subscribe(function() end)
		end)
		assert.is_false(ok)
		assert.matches("mergeSources must return an observable", failure, 1, true)
	end)

	it("expires records outside the configured interval window", function()
		local currentTime = 0
		local leftSubject, left = SchemaHelpers.subjectWithSchema("left")
		local rightSubject, right = SchemaHelpers.subjectWithSchema("right")

		local join, expired = JoinObservable.createJoinObservable(left, right, {
			on = "id",
			joinType = "outer",
			joinWindow = {
				mode = "interval",
				field = "ts",
				offset = 5,
				currentFn = function()
					return currentTime
				end,
			},
			flushOnComplete = false,
		})

		local pairs = {}
		join:subscribe(function(value)
			table.insert(pairs, value)
		end)

		local expiredEvents = {}
		expired:subscribe(function(record)
			table.insert(expiredEvents, record)
		end)

		currentTime = 0
		leftSubject:onNext({ schema = "left", id = 1, ts = 0 })
		currentTime = 3
		leftSubject:onNext({ schema = "left", id = 2, ts = 3 })
		currentTime = 7
		leftSubject:onNext({ schema = "left", id = 3, ts = 7 })

		rightSubject:onNext({ schema = "right", id = 2, ts = 7 })

		leftSubject:onCompleted()
		rightSubject:onCompleted()

		assert.are.same({
			{ left = 1, right = nil },
			{ left = 2, right = 2 },
		}, summarizePairs(pairs))

		local intervalExpired = {}
		for _, packet in ipairs(expiredEvents) do
			if packet.reason == "expired_interval" then
				local entry = expiredEntry(packet)
				table.insert(intervalExpired, entry and entry.id or nil)
			end
		end
		assert.are.same({ 1 }, intervalExpired)
	end)

	it("uses predicate-based expiration to drop unwanted entries", function()
		local leftSubject, left = SchemaHelpers.subjectWithSchema("left")
		local rightSubject, right = SchemaHelpers.subjectWithSchema("right")

		local join, expired = JoinObservable.createJoinObservable(left, right, {
			on = "id",
			joinType = "outer",
			joinWindow = {
				mode = "predicate",
				predicate = function(entry)
					return entry.keep
				end,
			},
		})

		local pairs = {}
		join:subscribe(function(value)
			table.insert(pairs, value)
		end)

		local expiredEvents = {}
		expired:subscribe(function(record)
			table.insert(expiredEvents, record)
		end)

		leftSubject:onNext({ schema = "left", id = 1, keep = false })
		leftSubject:onNext({ schema = "left", id = 2, keep = true })
		rightSubject:onNext({ schema = "right", id = 2 })

		leftSubject:onCompleted()
		rightSubject:onCompleted()

		assert.are.same({
			{ left = 1, right = nil },
			{ left = 2, right = 2 },
		}, summarizePairs(pairs))

		local predicateExpired = {}
		for _, packet in ipairs(expiredEvents) do
			if packet.reason == "expired_predicate" then
				local entry = expiredEntry(packet)
				table.insert(predicateExpired, entry and entry.id or nil)
			end
		end
			assert.are.same({ 1, 2 }, predicateExpired)
	end)

	it("supports the time alias for interval-based expiration", function()
		local currentTime = 0
		local previousEmitter = Log.setEmitter(function() end)

		local leftSubject, left = SchemaHelpers.subjectWithSchema("left")
		local rightSubject, right = SchemaHelpers.subjectWithSchema("right")

		local join, expired = JoinObservable.createJoinObservable(left, right, {
			on = "id",
			joinType = "outer",
			joinWindow = {
				mode = "time",
				ttl = 5,
				currentFn = function()
					return currentTime
				end,
			},
			flushOnComplete = false,
		})

		local pairs = {}
		join:subscribe(function(value)
			table.insert(pairs, value)
		end)

		local expiredEvents = {}
		expired:subscribe(function(record)
			table.insert(expiredEvents, record)
		end)

		currentTime = 0
		leftSubject:onNext({ schema = "left", id = 1, time = 0 })
		currentTime = 4
		leftSubject:onNext({ schema = "left", id = 2, time = 4 })
		currentTime = 7
		leftSubject:onNext({ schema = "left", id = 3, time = 7 })

		rightSubject:onNext({ schema = "right", id = 2, time = 7 })

		leftSubject:onCompleted()
		rightSubject:onCompleted()

		assert.are.same({
			{ left = 1, right = nil },
			{ left = 2, right = 2 },
		}, summarizePairs(pairs))

		local timeExpired = {}
		for _, packet in ipairs(expiredEvents) do
			if packet.reason == "expired_time" then
				local entry = expiredEntry(packet)
				table.insert(timeExpired, entry and entry.id or nil)
			end
		end
		assert.are.same({ 1 }, timeExpired)

		Log.setEmitter(previousEmitter)
	end)

	it("allows per-side expiration windows", function()
		local currentTime = 0

		local leftSubject, left = SchemaHelpers.subjectWithSchema("left")
		local rightSubject, right = SchemaHelpers.subjectWithSchema("right")

		local join, expired = JoinObservable.createJoinObservable(left, right, {
			on = "id",
			joinType = "outer",
			joinWindow = {
				left = {
					mode = "count",
					maxItems = 1,
				},
				right = {
					mode = "time",
					ttl = 5,
					field = "time",
					currentFn = function()
						return currentTime
					end,
				},
			},
		})

		local pairs = {}
		join:subscribe(function(value)
			table.insert(pairs, value)
		end)

		local expiredEvents = {}
		expired:subscribe(function(record)
			table.insert(expiredEvents, record)
		end)

		leftSubject:onNext({ schema = "left", id = 1 })
		leftSubject:onNext({ schema = "left", id = 2 })
		leftSubject:onNext({ schema = "left", id = 3 })

		currentTime = 0
		rightSubject:onNext({ schema = "right", id = 1, time = 0 })
		currentTime = 10
		rightSubject:onNext({ schema = "right", id = 2, time = 0 })
		currentTime = 2
		rightSubject:onNext({ schema = "right", id = 3, time = 2 })

		leftSubject:onCompleted()
		rightSubject:onCompleted()

			assert.are.same({
				{ left = 1, right = nil },
				{ left = 2, right = nil },
				{ left = 3, right = 3 },
				{ left = nil, right = 1 },
				{ left = nil, right = 2 },
			}, summarizePairs(pairs))

		local leftExpired = {}
		local rightExpired = {}
		for _, packet in ipairs(expiredEvents) do
			local entry = expiredEntry(packet)
			if packet.schema == "left" then
				table.insert(leftExpired, entry and entry.id or nil)
			else
				table.insert(rightExpired, entry and entry.id or nil)
			end
		end

		table.sort(leftExpired)
		table.sort(rightExpired)

			assert.are.same({ 1, 2, 3 }, leftExpired)
			assert.are.same({ 1, 2, 3 }, rightExpired)
	end)

	it("emits matched flag on expiration and eventually expires all inputs", function()
		local leftSubject, left = SchemaHelpers.subjectWithSchema("left")
		local rightSubject, right = SchemaHelpers.subjectWithSchema("right")

		local join, expired = JoinObservable.createJoinObservable(left, right, {
			on = "id",
			joinType = "left",
		})

		local expiredEvents = {}
		expired:subscribe(function(packet)
			expiredEvents[#expiredEvents + 1] = packet
		end)

		join:subscribe(function() end)

		leftSubject:onNext({ schema = "left", id = 1 })
		rightSubject:onNext({ schema = "right", id = 1 })
		leftSubject:onNext({ schema = "left", id = 2 }) -- unmatched

		leftSubject:onCompleted()
		rightSubject:onCompleted()

		local summary = {}
		for _, packet in ipairs(expiredEvents) do
			local entry, schema = expiredEntry(packet)
			summary[#summary + 1] = {
				schema = schema,
				id = entry and entry.id or nil,
				reason = packet.reason,
				matched = packet.matched,
			}
		end
		table.sort(summary, function(a, b)
			return (tostring(a.schema) .. tostring(a.id)) < (tostring(b.schema) .. tostring(b.id))
		end)

		assert.are.same({
			{ schema = "left", id = 1, reason = "completed", matched = true },
			{ schema = "left", id = 2, reason = "completed", matched = false },
			{ schema = "right", id = 1, reason = "completed", matched = true },
		}, summary)
	end)
end)

describe("JoinObservable.chain helper", function()
	local function makeResultWithOrder(id)
		local order = { id = id }
		order.RxMeta = { schema = "orders", schemaVersion = 1, joinKey = tostring(id) }
		return Result.new():attach("orders", order)
	end

	it("forwards schema streams lazily and cleans up subscriptions", function()
		local upstreamSubject = rx.Subject.create()
		local activeSubscriptions = 0

		local upstream = rx.Observable.create(function(observer)
			-- Explainer: counting subscriptions proves `JoinObservable.chain` only
			-- subscribes when needed and tears down the upstream when downstream unsubscribes.
			activeSubscriptions = activeSubscriptions + 1
			local sub = upstreamSubject:subscribe(observer)
			return function()
				activeSubscriptions = activeSubscriptions - 1
				sub:unsubscribe()
			end
		end)

		local chained = JoinObservable.chain(upstream, {
			schema = "orders",
			as = "orders_forward",
		})

		local seen = {}
		assert.are.equal(0, activeSubscriptions)
		local subscription = chained:subscribe(function(record)
			table.insert(seen, record)
		end, function(err)
			error(err)
		end)
		assert.are.equal(1, activeSubscriptions)

		upstreamSubject:onNext(makeResultWithOrder(1))
		assert.are.equal(1, #seen)
		assert.are.equal("orders_forward", seen[1].RxMeta.schema)

		subscription:unsubscribe()
		assert.are.equal(0, activeSubscriptions)
	end)

	it("applies map callbacks to enrich forwarded records", function()
		local upstreamSubject = rx.Subject.create()
		local chained = JoinObservable.chain(upstreamSubject, {
			from = "orders",
			as = "orders_enriched",
			map = function(orderRecord)
				orderRecord.tag = "enriched"
				return orderRecord
			end,
		})

		local seen = {}
		chained:subscribe(function(record)
			table.insert(seen, record)
		end, function(err)
			error(err)
		end)

		upstreamSubject:onNext(makeResultWithOrder(2))
		assert.are.equal(1, #seen)
		assert.are.equal("orders_enriched", seen[1].RxMeta.schema)
		assert.are.equal("enriched", seen[1].tag)
	end)

	it("supports forwarding multiple schemas in one call", function()
		local upstreamSubject = rx.Subject.create()
		local chained = JoinObservable.chain(upstreamSubject, {
			from = {
				{ schema = "orders", renameTo = "orders_a" },
				{ schema = "orders", renameTo = "orders_b" },
			},
		})

		local seenSchemas = {}
		chained:subscribe(function(record)
			table.insert(seenSchemas, record.RxMeta.schema)
		end, function(err)
			error(err)
		end)

		upstreamSubject:onNext(makeResultWithOrder(3))
		assert.are.same({ "orders_a", "orders_b" }, seenSchemas)
	end)

	it("keeps fan-out outputs independent and respects mapping order", function()
		local upstreamSubject = rx.Subject.create()
		local chained = JoinObservable.chain(upstreamSubject, {
			from = {
				{ schema = "orders", renameTo = "orders_first" },
				{ schema = "orders", renameTo = "orders_second" },
			},
		})

		local outputs = {}
		chained:subscribe(function(record)
			table.insert(outputs, record)
		end, function(err)
			error(err)
		end)

		local upstreamResult = makeResultWithOrder(11)
		local upstreamOrder = upstreamResult:get("orders")
		upstreamSubject:onNext(upstreamResult)

		assert.are.equal(2, #outputs)
		assert.are.same({ "orders_first", "orders_second" }, {
			outputs[1].RxMeta.schema,
			outputs[2].RxMeta.schema,
		})

		-- Mutating one output should not affect the other or upstream.
		outputs[1].id = 999
		assert.are.equal(11, outputs[2].id)
		assert.are.equal(11, upstreamOrder.id)
		assert.is_nil(upstreamOrder.tag)
	end)

	it("isolates mapper mutations across fan-out branches", function()
		local upstreamSubject = rx.Subject.create()
		local chained = JoinObservable.chain(upstreamSubject, {
			from = {
				{
					schema = "orders",
					renameTo = "orders_mapped",
					map = function(orderRecord)
						orderRecord.tag = (orderRecord.tag or 0) + 1
						return orderRecord
					end,
				},
				{ schema = "orders", renameTo = "orders_plain" },
			},
		})

		local mapped, plain
		chained:subscribe(function(record)
			if record.RxMeta.schema == "orders_mapped" then
				mapped = record
			elseif record.RxMeta.schema == "orders_plain" then
				plain = record
			end
		end, function(err)
			error(err)
		end)

		upstreamSubject:onNext(makeResultWithOrder(12))

		assert.is_not_nil(mapped)
		assert.is_not_nil(plain)
		assert.are_equal(1, mapped.tag)
		assert.is_nil(plain.tag)
		assert.are_not.equal(mapped, plain)
	end)

	it("disposes the upstream when a mapper errors", function()
		local upstreamSubject = rx.Subject.create()
		local activeSubscriptions = 0

		local upstream = rx.Observable.create(function(observer)
			activeSubscriptions = activeSubscriptions + 1
			local sub = upstreamSubject:subscribe(observer)
			return function()
				activeSubscriptions = activeSubscriptions - 1
				sub:unsubscribe()
			end
		end)

		local chained = JoinObservable.chain(upstream, {
			schema = "orders",
			map = function()
				error("mapper failed")
			end,
		})

		local errMessage
		local subscription = chained:subscribe(function()
			error("should not emit")
		end, function(err)
			errMessage = err
		end)

		assert.are.equal(1, activeSubscriptions)
		upstreamSubject:onNext(makeResultWithOrder(9))

		assert.matches("mapper failed", errMessage, 1, true)
		assert.are.equal(0, activeSubscriptions)

		-- Further emissions should be ignored because the upstream is torn down.
		upstreamSubject:onNext(makeResultWithOrder(10))
		subscription:unsubscribe()
	end)

	it("preserves join metadata when chaining asymmetric key selectors", function()
	local orders = SchemaHelpers.observableFromTable("orders", {
		{ orderId = 501, customerId = 1 },
		{ orderId = 502, customerId = 2 },
	}, { idField = "orderId" })

		local customers = SchemaHelpers.observableFromTable("customers", {
			{ id = 1 },
			{ id = 2 },
		})

		local join = JoinObservable.createJoinObservable(orders, customers, {
			on = ordersCustomersOn,
			joinType = "inner",
		})

		local forwarded = JoinObservable.chain(join, {
			schema = "orders",
			as = "forwarded_orders",
			map = function(orderRecord)
				return { invoiceId = orderRecord.orderId }
			end,
		})

		local forwardedValues, completed, err = collectValues(forwarded)
		assert.is_nil(err)
		assert.is_true(completed)
		assert.are.equal(2, #forwardedValues)

		local summary = {}
		for _, record in ipairs(forwardedValues) do
			table.insert(summary, {
				invoiceId = record.invoiceId,
				schema = record.RxMeta and record.RxMeta.schema,
				joinKey = record.RxMeta and record.RxMeta.joinKey,
			})
		end

		table.sort(summary, function(a, b)
			return a.invoiceId < b.invoiceId
		end)

		assert.are.same({
			{ invoiceId = 501, schema = "forwarded_orders", joinKey = 1 },
			{ invoiceId = 502, schema = "forwarded_orders", joinKey = 2 },
		}, summary)
	end)

	it("warns and skips mappings for missing schemas", function()
		local upstreamSubject = rx.Subject.create()
		local chained = JoinObservable.chain(upstreamSubject, {
			from = {
				{ schema = "orders" },
				{ schema = "missing_schema" },
			},
		})

		local warnings = withCapturedWarnings(function(captured)
			warnings = captured
			local seen = {}
			chained:subscribe(function(record)
				table.insert(seen, record.RxMeta.schema)
			end, function(err)
				error(err)
			end)

			upstreamSubject:onNext(makeResultWithOrder(14))
			assert.are.same({ "orders" }, seen)
		end)

		assert.is_true(#warnings >= 1)
		assert.matches("missing_schema", warnings[1], 1, true)
	end)

	it("backfills RxMeta when mapper returns a bare table", function()
		local upstreamSubject = rx.Subject.create()
		local chained = JoinObservable.chain(upstreamSubject, {
			schema = "orders",
			map = function()
				return { invoiceId = 15 }
			end,
		})

		local seen
		chained:subscribe(function(record)
			seen = record
		end, function(err)
			error(err)
		end)

		upstreamSubject:onNext(makeResultWithOrder(15))

		assert.is_not_nil(seen)
		assert.are.equal("orders", seen.RxMeta.schema)
		assert.are.equal("15", tostring(seen.RxMeta.joinKey))
		assert.are.equal(15, seen.invoiceId)
	end)
end)
