local package = require("package")
package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require("bootstrap")

local JoinObservable = require("JoinObservable")
local Schema = require("JoinObservable.schema")
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
			expirationWindow = {
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
end)
