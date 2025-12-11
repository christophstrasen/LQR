local package = require("package")
package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require('LQR/bootstrap')

local JoinObservable = require("LQR/JoinObservable/init")
local Schema = require("LQR/JoinObservable/schema")
local rx = require("reactivex")

local function summarizePairs(pairs)
	local summary = {}
	for _, result in ipairs(pairs) do
		table.insert(summary, {
			left = result and result:get("left"),
			right = result and result:get("right"),
		})
	end
	return summary
end

local function observableFromTable(schema, rows)
	local source = rx.Observable.fromTable(rows, ipairs, true)
	return Schema.wrap(schema, source, { idField = "id" })
end

describe("JoinObservable periodic GC", function()
	it("runs interval expiration even when no new records arrive when gcScheduleFn is provided", function()
		local scheduledTick
		local function scheduleFn(_delay, fn)
			scheduledTick = fn
			return { unsubscribe = function() end }
		end

		local leftSubject = rx.Subject.create()
		local rightSubject = rx.Subject.create()
		local left = Schema.wrap("left", leftSubject, { idField = "id" })
		local right = Schema.wrap("right", rightSubject, { idField = "id" })

		local currentTime = 0
		local join, expired = JoinObservable.createJoinObservable(left, right, {
			on = "id",
			joinType = "left",
			joinWindow = {
				mode = "interval",
				field = "ts",
				offset = 1,
				currentFn = function()
					return currentTime
				end,
			},
			gcIntervalSeconds = 0.1,
			gcScheduleFn = scheduleFn,
			flushOnComplete = false,
		})

		local expiredPackets = {}
		expired:subscribe(function(packet)
			table.insert(expiredPackets, packet)
		end)
		-- Activate join subscription so GC setup runs.
		join:subscribe(function() end)

		-- Emit one record; do not complete yet.
		leftSubject:onNext({ id = 1, ts = 0 })

		assert.are.same({}, expiredPackets)

		-- Bump time so the interval enforcer considers the record stale,
		-- then run the scheduled GC once.
		currentTime = 10
		assert.is_not_nil(scheduledTick)
		scheduledTick()

		-- Complete after the GC tick.
		leftSubject:onCompleted()
		rightSubject:onCompleted()

		local reasons = {}
		for _, packet in ipairs(expiredPackets) do
			reasons[#reasons + 1] = packet.reason
		end

		assert.are.same({ "expired_interval" }, reasons)
	end)

	it("sweeps both caches on insert so stale opposite-side records expire", function()
		local leftSubject = rx.Subject.create()
		local rightSubject = rx.Subject.create()
		local left = Schema.wrap("left", leftSubject, { idField = "id" })
		local right = Schema.wrap("right", rightSubject, { idField = "id" })

		local currentTime = 0
		local join, expired = JoinObservable.createJoinObservable(left, right, {
			on = "id",
			joinType = "outer",
			joinWindow = {
				mode = "interval",
				field = "ts",
				offset = 1,
				currentFn = function()
					return currentTime
				end,
			},
		})

		local expiredPackets = {}
		expired:subscribe(function(packet)
			table.insert(expiredPackets, packet)
		end)
		join:subscribe(function() end)

		-- Seed the right cache with a record that will age out.
		rightSubject:onNext({ id = 1, ts = 0 })
		assert.are.same({}, expiredPackets)

		-- Advance time past the interval window and insert on the left to trigger GC.
		currentTime = 5
		leftSubject:onNext({ id = 2, ts = 5 })

		assert.are.equal(1, #expiredPackets)
		assert.are.equal("right", expiredPackets[1].schema)
		assert.are.equal("expired_interval", expiredPackets[1].reason)
	end)

	it("can defer per-insert GC when gcOnInsert=false and rely on periodic GC instead", function()
		local scheduledTick
		local function scheduleFn(_delay, fn)
			scheduledTick = fn
			return { unsubscribe = function() end }
		end

		local leftSubject = rx.Subject.create()
		local rightSubject = rx.Subject.create()
		local left = Schema.wrap("left", leftSubject, { idField = "id" })
		local right = Schema.wrap("right", rightSubject, { idField = "id" })

		local join, expired = JoinObservable.createJoinObservable(left, right, {
			on = "id",
			joinType = "outer",
			gcOnInsert = false,
			joinWindow = {
				mode = "count",
				maxItems = 1,
			},
			gcIntervalSeconds = 0.1,
			gcScheduleFn = scheduleFn,
			flushOnComplete = true,
		})

		local pairs = {}
		join:subscribe(function(result)
			local left = result:get("left")
			local right = result:get("right")
			pairs[#pairs + 1] = {
				left = left and left.id or nil,
				right = right and right.id or nil,
			}
		end)

		local expiredPackets = {}
		expired:subscribe(function(packet)
			expiredPackets[#expiredPackets + 1] = packet
		end)

		leftSubject:onNext({ id = 1 })
		leftSubject:onNext({ id = 2 })

		-- Without per-insert GC, nothing is expired yet.
		assert.are.same({}, pairs)
		assert.are.same({}, expiredPackets)

		-- Trigger periodic GC once; oldest entry should be evicted.
		assert.is_not_nil(scheduledTick)
		scheduledTick()

		leftSubject:onCompleted()
		rightSubject:onCompleted()

		local expiredIds = {}
		local expiredReasons = {}
		for _, packet in ipairs(expiredPackets) do
			local entry = packet.result and packet.result:get(packet.schema)
			expiredIds[#expiredIds + 1] = entry and entry.id or nil
			expiredReasons[#expiredReasons + 1] = packet.reason
		end

			assert.are.same({ 1, 2 }, expiredIds)
			assert.are.same({ "evicted", "completed" }, expiredReasons)

		assert.are.same({
			{ left = 1, right = nil },
			{ left = 2, right = nil },
		}, pairs)
	end)

	it("cancels periodic GC when scheduler returns a callable handle", function()
		local canceled = 0
		local function scheduleFn(_delay, fn)
			-- Ignore the tick; return a canceler function instead of an object.
			return function()
				canceled = canceled + 1
			end
		end

		local leftSubject = rx.Subject.create()
		local rightSubject = rx.Subject.create()
		local left = Schema.wrap("left", leftSubject, { idField = "id" })
		local right = Schema.wrap("right", rightSubject, { idField = "id" })

		local join = JoinObservable.createJoinObservable(left, right, {
			on = "id",
			gcIntervalSeconds = 0.1,
			gcScheduleFn = scheduleFn,
		})

		local subscription = join:subscribe(function() end)
		assert.are.equal(0, canceled)

		subscription:unsubscribe()
		assert.are.equal(1, canceled)

		-- No double-cancel on repeated unsubscription.
		subscription:unsubscribe()
		assert.are.equal(1, canceled)
	end)
end)
