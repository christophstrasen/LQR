local package = require("package")
package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require("bootstrap")

local rx = require("reactivex")
local JoinObservable = require("JoinObservable")
local Schema = require("JoinObservable.schema")
local Result = require("JoinObservable.result")

---@diagnostic disable: undefined-global
---@diagnostic disable: undefined-field
	describe("JoinObservable", function()
		after_each(function()
			JoinObservable.setWarningHandler()
		end)

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

	local function observableFromTable(schemaName, rows)
		return Schema.wrap(schemaName, rx.Observable.fromTable(rows, ipairs, true))
	end

	local function subjectWithSchema(schemaName)
		local source = rx.Subject.create()
		return source, Schema.wrap(schemaName, source)
	end

	local function expiredEntry(packet)
		if not packet then
			return nil, nil
		end
		local alias = packet.alias or "unknown"
		local entry = packet.result and packet.result:get(alias)
		return entry, alias
	end

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
		assert.are.same({ "customers", "orders" }, result:aliases())
	end)

	it("clones aliases without mutating the source", function()
		local result = buildResult()
		local clone = result:clone()

		assert.are_not.equal(result:get("orders"), clone:get("orders"))
		clone:get("orders").customerId = 999
		assert.are.equal(1, result:get("orders").customerId)
	end)

	it("selects and renames aliases", function()
		local result = buildResult()
		local renamed = Result.selectAliases(result, { customers = "buyer" })
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
		local firstWrapped = Schema.wrap("orders", sourceSubject)
			local secondWrapped = Schema.wrap("orders", bufferSubject)

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

	it("emits only matched pairs for an inner join", function()
		local left = observableFromTable("left", {
			{ schema = "left", id = 1 },
			{ schema = "left", id = 2 },
		})

		local right = observableFromTable("right", {
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
		local left = observableFromTable("left", {
			{ schema = "left", id = 10 },
			{ schema = "left", id = 20 },
		})

		local right = observableFromTable("right", {
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

	it("surfaces expired records via the secondary observable", function()
		local left = observableFromTable("left", {
			{ schema = "left", id = 1 },
			{ schema = "left", id = 2 },
		})

		local right = observableFromTable("right", {
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
			local entry, alias = expiredEntry(packet)
			if entry then
				expiredIds[entry.id] = alias
			end
		end
		assert.are.same({
			[1] = "left",
			[2] = "left",
			[3] = "right",
		}, expiredIds)
	end)

	it("evicts the oldest cached entries when the cache exceeds the cap", function()
		local leftSubject, left = subjectWithSchema("left")
		local rightSubject, right = subjectWithSchema("right")

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
			{ left = 3, right = 3 },
		}, summarizePairs(pairs))

		local leftExpired = {}
		for _, packet in ipairs(expiredEvents) do
			if packet.alias == "left" then
				table.insert(leftExpired, packet)
			end
		end

		assert.are.same(2, #leftExpired)
		assert.are.same({ "evicted", "evicted" }, {
			leftExpired[1].reason,
			leftExpired[2].reason,
		})
		local entryOne = expiredEntry(leftExpired[1])
		local entryTwo = expiredEntry(leftExpired[2])
		assert.are.same({ 1, 2 }, { entryOne and entryOne.id, entryTwo and entryTwo.id })
	end)

	it("only keeps the newest key available for future matches when entries are evicted", function()
		local leftSubject, left = subjectWithSchema("left")
		local rightSubject, right = subjectWithSchema("right")

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

		assert.are.equal(2, #expiredEvents)
		assert.are.same({ "left", "left" }, {
			expiredEvents[1].alias,
			expiredEvents[2].alias,
		})
		assert.are.same({ "evicted", "evicted" }, {
			expiredEvents[1].reason,
			expiredEvents[2].reason,
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
			{ left = 3, right = 3 },
		}, summarizePairs(pairs))
	end)

	it("supports functional key selectors", function()
		local left = observableFromTable("left", {
			{ schema = "left", partition = "alpha", localId = 1 },
			{ schema = "left", partition = "beta", localId = 1 },
		})

		local right = observableFromTable("right", {
			{ schema = "right", partition = "alpha", localId = 1 },
			{ schema = "right", partition = "beta", localId = 2 },
			{ schema = "right", partition = "beta", localId = 1 },
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

	it("never emits expiration events for matched records", function()
		local leftSubject, left = subjectWithSchema("left")
		local rightSubject, right = subjectWithSchema("right")

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
		assert.are.equal(0, #expiredEvents)
	end)

	it("ignores malformed records emitted by a custom merge observable", function()
		JoinObservable.setWarningHandler(function() end)

		local left = observableFromTable("left", {
			{ schema = "left", id = 5 },
		})

		local right = observableFromTable("right", {
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
		assert.are.equal(0, #expiredEvents)
	end)

	it("propagates merge errors to both the result and expiration observables", function()
		local left = observableFromTable("left", {
			{ schema = "left", id = 1 },
		})
		local right = observableFromTable("right", {
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
		local leftSubject, left = subjectWithSchema("left")
		local rightSubject, right = subjectWithSchema("right")

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
		local previousHandler = JoinObservable.setWarningHandler(function() end)

		local left = observableFromTable("left", {
			{ schema = "left", id = 1 },
			{ schema = "left" }, -- missing id -> nil key
			{ schema = "left", id = 2 },
		})

		local right = observableFromTable("right", {
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

		assert.are.equal(0, #expiredEvents)

		JoinObservable.setWarningHandler(previousHandler)
	end)

	it("honors custom merge ordering and validates the merge contract", function()
		local left = observableFromTable("left", {
			{ schema = "left", id = 1 },
		})

		local right = observableFromTable("right", {
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
		local leftSubject, left = subjectWithSchema("left")
		local rightSubject, right = subjectWithSchema("right")

		local join, expired = JoinObservable.createJoinObservable(left, right, {
			on = "id",
			joinType = "outer",
			expirationWindow = {
				mode = "interval",
				field = "ts",
				offset = 5,
				currentFn = function()
					return currentTime
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
		local leftSubject, left = subjectWithSchema("left")
		local rightSubject, right = subjectWithSchema("right")

		local join, expired = JoinObservable.createJoinObservable(left, right, {
			on = "id",
			joinType = "outer",
			expirationWindow = {
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
		assert.are.same({ 1 }, predicateExpired)
	end)

	it("supports the time alias for interval-based expiration", function()
		local currentTime = 0
		local previousHandler = JoinObservable.setWarningHandler(function() end)

		local leftSubject, left = subjectWithSchema("left")
		local rightSubject, right = subjectWithSchema("right")

		local join, expired = JoinObservable.createJoinObservable(left, right, {
			on = "id",
			joinType = "outer",
			expirationWindow = {
				mode = "time",
				ttl = 5,
				currentFn = function()
					return currentTime
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

		JoinObservable.setWarningHandler(previousHandler)
	end)

	it("allows per-side expiration windows", function()
		local currentTime = 0

		local leftSubject, left = subjectWithSchema("left")
		local rightSubject, right = subjectWithSchema("right")

		local join, expired = JoinObservable.createJoinObservable(left, right, {
			on = "id",
			joinType = "outer",
			expirationWindow = {
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
			if packet.alias == "left" then
				table.insert(leftExpired, entry and entry.id or nil)
			else
				table.insert(rightExpired, entry and entry.id or nil)
			end
		end

		table.sort(leftExpired)
		table.sort(rightExpired)

		assert.are.same({ 1, 2 }, leftExpired)
		assert.are.same({ 1, 2 }, rightExpired)
	end)
end)

describe("JoinObservable.chain helper", function()
	local function makeResultWithOrder(id)
		local order = { id = id }
		order.RxMeta = { schema = "orders", schemaVersion = 1, joinKey = tostring(id) }
		return Result.new():attach("orders", order)
	end

	it("forwards aliases lazily and cleans up subscriptions", function()
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
			alias = "orders",
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

		local seenAliases = {}
		chained:subscribe(function(record)
			table.insert(seenAliases, record.RxMeta.schema)
		end, function(err)
			error(err)
		end)

		upstreamSubject:onNext(makeResultWithOrder(3))
		assert.are.same({ "orders_a", "orders_b" }, seenAliases)
	end)
end)
