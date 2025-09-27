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
end)
