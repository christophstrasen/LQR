local package = require("package")
package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require("bootstrap")

local rx = require("reactivex")
local JoinObservable = require("JoinObservable")

---@diagnostic disable: undefined-global
---@diagnostic disable: undefined-field
describe("JoinObservable", function()
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
		expired:subscribe(function(packet)
			table.insert(expiredEvents, packet)
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
			expiredIds[packet.entry.id] = packet.side
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
		expired:subscribe(function(packet)
			table.insert(expiredEvents, packet)
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
		for _, packet in ipairs(expiredEvents) do
			if packet.side == "left" then
				table.insert(leftExpired, packet)
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
end)
