local package = require("package")
package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require("bootstrap")

local rx = require("reactivex")
local JoinObservable = require("JoinObservable")

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
			local leftId = pair.left and pair.left.id or nil
			local rightId = pair.right and pair.right.id or nil
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

	it("emits only matched pairs for an inner join", function()
		local left = rx.Observable.fromTable({
			{ schema = "left", id = 1 },
			{ schema = "left", id = 2 },
		}, ipairs, true)

		local right = rx.Observable.fromTable({
			{ schema = "right", id = 2 },
			{ schema = "right", id = 3 },
		}, ipairs, true)

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
		local left = rx.Observable.fromTable({
			{ schema = "left", id = 10 },
			{ schema = "left", id = 20 },
		}, ipairs, true)

		local right = rx.Observable.fromTable({
			{ schema = "right", id = 20 },
			{ schema = "right", id = 30 },
		}, ipairs, true)

		local defaultJoin = JoinObservable.createJoinObservable(left, right)
		local pairs, completed, err = collectValues(defaultJoin)

		assert.is_nil(err)
		assert.is_true(completed)
		assert.are.same({
			{ left = 20, right = 20 },
		}, summarizePairs(pairs))
	end)

	it("surfaces expired records via the secondary observable", function()
		local left = rx.Observable.fromTable({
			{ schema = "left", id = 1 },
			{ schema = "left", id = 2 },
		}, ipairs, true)

		local right = rx.Observable.fromTable({
			{ schema = "right", id = 3 },
		}, ipairs, true)

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
		for _, record in ipairs(expiredEvents) do
			expiredIds[record.entry.id] = record.side
		end
		assert.are.same({
			[1] = "left",
			[2] = "left",
			[3] = "right",
		}, expiredIds)
	end)

	it("evicts the oldest cached entries when the cache exceeds the cap", function()
		local left = rx.Subject.create()
		local right = rx.Subject.create()

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

		left:onNext({ schema = "left", id = 1 })
		left:onNext({ schema = "left", id = 2 })
		left:onNext({ schema = "left", id = 3 })

		right:onNext({ schema = "right", id = 1 })
		right:onNext({ schema = "right", id = 2 })
		right:onNext({ schema = "right", id = 3 })

		left:onCompleted()
		right:onCompleted()

		assert.are.same({
			{ left = 3, right = 3 },
		}, summarizePairs(pairs))

		local leftExpired = {}
		for _, record in ipairs(expiredEvents) do
			if record.side == "left" then
				table.insert(leftExpired, record)
			end
		end

		assert.are.same(2, #leftExpired)
		assert.are.same({ "evicted", "evicted" }, {
			leftExpired[1].reason,
			leftExpired[2].reason,
		})
		assert.are.same({ 1, 2 }, {
			leftExpired[1].entry.id,
			leftExpired[2].entry.id,
			})
	end)

	it("only keeps the newest key available for future matches when entries are evicted", function()
		local left = rx.Subject.create()
		local right = rx.Subject.create()

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

		left:onNext({ schema = "left", id = 1 })
		left:onNext({ schema = "left", id = 2 })
		left:onNext({ schema = "left", id = 3 })

		assert.are.equal(2, #expiredEvents)
		assert.are.same({ "left", "left" }, {
			expiredEvents[1].side,
			expiredEvents[2].side,
		})
		assert.are.same({ "evicted", "evicted" }, {
			expiredEvents[1].reason,
			expiredEvents[2].reason,
		})
		assert.are.same({ 1, 2 }, {
			expiredEvents[1].entry.id,
			expiredEvents[2].entry.id,
		})

		right:onNext({ schema = "right", id = 1 })
		right:onNext({ schema = "right", id = 2 })
		right:onNext({ schema = "right", id = 3 })
		right:onCompleted()
		left:onCompleted()

		assert.are.same({
			{ left = 3, right = 3 },
		}, summarizePairs(pairs))
	end)

	it("supports functional key selectors", function()
		local left = rx.Observable.fromTable({
			{ schema = "left", partition = "alpha", localId = 1 },
			{ schema = "left", partition = "beta", localId = 1 },
		}, ipairs, true)

		local right = rx.Observable.fromTable({
			{ schema = "right", partition = "alpha", localId = 1 },
			{ schema = "right", partition = "beta", localId = 2 },
			{ schema = "right", partition = "beta", localId = 1 },
		}, ipairs, true)

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
			local leftKey = ("%s:%s"):format(pair.left.partition, pair.left.localId)
			local rightKey = ("%s:%s"):format(pair.right.partition, pair.right.localId)
			table.insert(matchedKeys, leftKey .. "|" .. rightKey)
		end
		table.sort(matchedKeys)

		assert.are.same({
			"alpha:1|alpha:1",
			"beta:1|beta:1",
		}, matchedKeys)
	end)

	it("never emits expiration events for matched records", function()
		local left = rx.Subject.create()
		local right = rx.Subject.create()

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

		left:onNext({ schema = "left", id = 42 })
		right:onNext({ schema = "right", id = 42 })
		left:onCompleted()
		right:onCompleted()

		assert.are.same({
			{ left = 42, right = 42 },
		}, summarizePairs(pairs))
		assert.are.equal(0, #expiredEvents)
	end)

	it("ignores malformed records emitted by a custom merge observable", function()
		JoinObservable.setWarningHandler(function() end)

		local left = rx.Observable.fromTable({
			{ schema = "left", id = 5 },
		}, ipairs, true)

		local right = rx.Observable.fromTable({
			{ schema = "right", id = 5 },
		}, ipairs, true)

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
		local left = rx.Observable.fromTable({
			{ schema = "left", id = 1 },
		}, ipairs, true)
		local right = rx.Observable.fromTable({
			{ schema = "right", id = 1 },
		}, ipairs, true)

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
		local left = rx.Subject.create()
		local right = rx.Subject.create()

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

		left:onNext({ schema = "left", id = 7 })

		assert.are.equal(0, expiredCompletions)

		subscription:unsubscribe()

		assert.are.equal(1, expiredCompletions)
		assert.are.equal(0, expiredErrors)

		-- Ensure no further completion occurs if we unsubscribe again or touch subjects.
		subscription:unsubscribe()
		left:onNext({ schema = "left", id = 8 })
		assert.are.equal(1, expiredCompletions)
	end)

	it("drops entries whose key selector returns nil", function()
		local previousHandler = JoinObservable.setWarningHandler(function() end)

		local left = rx.Observable.fromTable({
			{ schema = "left", id = 1 },
			{ schema = "left" }, -- missing id -> nil key
			{ schema = "left", id = 2 },
		}, ipairs, true)

		local right = rx.Observable.fromTable({
			{ schema = "right", id = 1 },
			{ schema = "right", id = 2 },
		}, ipairs, true)

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
		local left = rx.Observable.fromTable({
			{ schema = "left", id = 1 },
		}, ipairs, true)

		local right = rx.Observable.fromTable({
			{ schema = "right", id = 1 },
			{ schema = "right", id = 2 },
		}, ipairs, true)

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
		local left = rx.Subject.create()
		local right = rx.Subject.create()

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
		left:onNext({ schema = "left", id = 1, ts = 0 })
		currentTime = 3
		left:onNext({ schema = "left", id = 2, ts = 3 })
		currentTime = 7
		left:onNext({ schema = "left", id = 3, ts = 7 })

		right:onNext({ schema = "right", id = 2, ts = 7 })

		left:onCompleted()
		right:onCompleted()

		assert.are.same({
			{ left = 1, right = nil },
			{ left = 2, right = 2 },
		}, summarizePairs(pairs))

		local intervalExpired = {}
		for _, record in ipairs(expiredEvents) do
			if record.reason == "expired_interval" then
				table.insert(intervalExpired, record.entry.id)
			end
		end
		assert.are.same({ 1 }, intervalExpired)
	end)

	it("uses predicate-based expiration to drop unwanted entries", function()
		local left = rx.Subject.create()
		local right = rx.Subject.create()

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

		left:onNext({ schema = "left", id = 1, keep = false })
		left:onNext({ schema = "left", id = 2, keep = true })
		right:onNext({ schema = "right", id = 2 })

		left:onCompleted()
		right:onCompleted()

		assert.are.same({
			{ left = 1, right = nil },
			{ left = 2, right = 2 },
		}, summarizePairs(pairs))

		local predicateExpired = {}
		for _, record in ipairs(expiredEvents) do
			if record.reason == "expired_predicate" then
				table.insert(predicateExpired, record.entry.id)
			end
		end
		assert.are.same({ 1 }, predicateExpired)
	end)

	it("supports the time alias for interval-based expiration", function()
		local currentTime = 0
		local previousHandler = JoinObservable.setWarningHandler(function() end)

		local left = rx.Subject.create()
		local right = rx.Subject.create()

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
		left:onNext({ schema = "left", id = 1, time = 0 })
		currentTime = 4
		left:onNext({ schema = "left", id = 2, time = 4 })
		currentTime = 7
		left:onNext({ schema = "left", id = 3, time = 7 })

		right:onNext({ schema = "right", id = 2, time = 7 })

		left:onCompleted()
		right:onCompleted()

		assert.are.same({
			{ left = 1, right = nil },
			{ left = 2, right = 2 },
		}, summarizePairs(pairs))

		local timeExpired = {}
		for _, record in ipairs(expiredEvents) do
			if record.reason == "expired_time" then
				table.insert(timeExpired, record.entry.id)
			end
		end
		assert.are.same({ 1 }, timeExpired)

		JoinObservable.setWarningHandler(previousHandler)
	end)

	it("allows per-side expiration windows", function()
		local currentTime = 0

		local left = rx.Subject.create()
		local right = rx.Subject.create()

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

		left:onNext({ schema = "left", id = 1 })
		left:onNext({ schema = "left", id = 2 })
		left:onNext({ schema = "left", id = 3 })

		currentTime = 0
		right:onNext({ schema = "right", id = 1, time = 0 })
		currentTime = 10
		right:onNext({ schema = "right", id = 2, time = 0 })
		currentTime = 2
		right:onNext({ schema = "right", id = 3, time = 2 })

		left:onCompleted()
		right:onCompleted()

		assert.are.same({
			{ left = 1, right = nil },
			{ left = 2, right = nil },
			{ left = 3, right = 3 },
			{ left = nil, right = 1 },
			{ left = nil, right = 2 },
		}, summarizePairs(pairs))

		local leftExpired = {}
		local rightExpired = {}
		for _, record in ipairs(expiredEvents) do
			if record.side == "left" then
				table.insert(leftExpired, record.entry.id)
			else
				table.insert(rightExpired, record.entry.id)
			end
		end

		table.sort(leftExpired)
		table.sort(rightExpired)

		assert.are.same({ 1, 2 }, leftExpired)
		assert.are.same({ 1, 2 }, rightExpired)
	end)
end)
