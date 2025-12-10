local package = require("package")
package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require('LQR.bootstrap')

local Query = require("LQR.Query")
local JoinObservable = require("LQR.JoinObservable")
local SchemaHelpers = require("tests.support.schema_helpers")
local Log = require("LQR.util.log")

---@diagnostic disable: undefined-global
describe("Join high-level facade", function()
	after_each(function()
		Log.setEmitter()
	end)

	local function withCapturedWarnings(run)
		local captured = {}
		local previous = Log.setEmitter(function(level, message, tag)
			if level == "warn" and (not tag or tag == "join" or tag == "query") then
				captured[#captured + 1] = message
			end
		end)
		local ok, err = pcall(run, captured)
		Log.setEmitter(previous)
		if not ok then
			error(err)
		end
		return captured
	end

local function collect(resultStream)
	local buffer = {}
	resultStream:subscribe(function(value)
		buffer[#buffer + 1] = value
	end)
	return buffer
end

local function summarizePair(result)
	if not result then
		return {}
	end
	local left = result:get("left")
	local right = result:get("right")
	return {
		left = left and left.id or left and left.orderId or nil,
		right = right and right.id or right and right.orderId or nil,
	}
end

	it("raises configuration errors when using lacks coverage for known schemas", function()
		local left = SchemaHelpers.observableFromTable("left", { { id = 1 } })
		local right = SchemaHelpers.observableFromTable("right", { { id = 1 } })

		assert.has_error(function()
			Query.from(left, "left")
				:innerJoin(right, "right")
				:using({ left = { field = "id" } }) -- missing right
		end)
	end)

	it("auto-chains JoinResults into subsequent joins", function()
		local customersSubject, customers = SchemaHelpers.subjectWithSchema("customers", { idField = "id" })
		local ordersSubject, orders = SchemaHelpers.subjectWithSchema("orders", { idField = "id" })
		local refundsSubject, refunds = SchemaHelpers.subjectWithSchema("refunds", { idField = "id" })

		local joined = Query.from(customers, "customers")
			:leftJoin(orders, "orders")
			:using({ customers = { field = "id" }, orders = { field = "customerId" } })
			:innerJoin(refunds, "refunds")
			:using({ orders = { field = "id" }, refunds = { field = "orderId" } })
			:selectSchemas({ "customers", "orders", "refunds" })

		local results = {}
		joined:subscribe(function(result)
			results[#results + 1] = result
		end)

		customersSubject:onNext({ id = 1, name = "Ada" })
		ordersSubject:onNext({ id = 101, customerId = 1 })
		refundsSubject:onNext({ id = 201, orderId = 101 })

		customersSubject:onCompleted()
		ordersSubject:onCompleted()
		refundsSubject:onCompleted()

		assert.are.equal(1, #results)
		local first = results[1]
		assert.are.equal("Ada", first:get("customers").name)
		assert.are.equal(101, first:get("orders").id)
		assert.are.equal(201, first:get("refunds").id)
	end)

	it("emits expired packets with count windows and completion", function()
		local leftSubject, left = SchemaHelpers.subjectWithSchema("left", { idField = "id" })
		local rightSubject, right = SchemaHelpers.subjectWithSchema("right", { idField = "id" })

		local joined = Query.from(left, "left")
			:leftJoin(right, "right")
			:using({ left = { field = "id" }, right = { field = "id" } })
			:joinWindow({ count = 1 })

		local expiredPackets = collect(joined:expired())

		joined:subscribe(function() end)

		leftSubject:onNext({ id = 1 })
		leftSubject:onNext({ id = 2 })
		leftSubject:onCompleted()
		rightSubject:onCompleted()

		local expiredIds, expiredReasons = {}, {}
		for _, packet in ipairs(expiredPackets) do
			local entry = packet.result and packet.result:get(packet.schema)
			expiredIds[#expiredIds + 1] = entry and entry.id or nil
			expiredReasons[#expiredReasons + 1] = packet.reason
		end

			assert.are.same({ 1, 2 }, expiredIds)
			assert.are.same({ "evicted", "completed" }, expiredReasons)
	end)

	it("honors bufferSize configured via on table entries", function()
		local leftSubject, left = SchemaHelpers.subjectWithSchema("left", { idField = "id" })
		local rightSubject, right = SchemaHelpers.subjectWithSchema("right", { idField = "id" })

		local joined = Query.from(left, "left")
			:leftJoin(right, "right")
			:using({
				left = { field = "id", bufferSize = 1 }, -- distinct
				right = { field = "id", bufferSize = 2 }, -- allow two rights per key
			})
			:joinWindow({ count = 5 })

		local pairs = {}
		local expiredPackets = {}

		joined:subscribe(function(result)
			pairs[#pairs + 1] = result
		end)
		joined:expired():subscribe(function(packet)
			expiredPackets[#expiredPackets + 1] = packet
		end)

		leftSubject:onNext({ id = 1, side = "L1" })
		rightSubject:onNext({ id = 1, side = "R1" })
		rightSubject:onNext({ id = 1, side = "R2" })
		rightSubject:onNext({ id = 1, side = "R3" }) -- should evict oldest right (R1) because bufferSize=2

		leftSubject:onCompleted()
		rightSubject:onCompleted()

		-- The left buffer is distinct (size 1), so only one left is ever cached.
		-- Right buffer keeps the last two rights; matches fan out to all buffered partners.
		local summary = {}
		for _, pair in ipairs(pairs) do
			summary[#summary + 1] = summarizePair(pair)
		end
			-- Three matches because the single left fan-outs to each buffered right (capacity 2).
			assert.are.same(3, #summary)

		-- Oldest right was evicted due to bufferSize=2.
		local evictedRights = {}
		for _, packet in ipairs(expiredPackets) do
			if packet.schema == "right" then
				local entry = packet.result and packet.result:get("right")
				evictedRights[#evictedRights + 1] = { id = entry and entry.id or nil, reason = packet.reason }
			end
		end
		assert.is_true(#evictedRights >= 1)
	end)

	it("applies per-side bufferSize independently for left and right", function()
		local leftSubject, left = SchemaHelpers.subjectWithSchema("left", { idField = "id" })
		local rightSubject, right = SchemaHelpers.subjectWithSchema("right", { idField = "id" })

		local capturedOpts
		local originalCreate = JoinObservable.createJoinObservable
		local function restore()
			JoinObservable.createJoinObservable = originalCreate
		end

		local ok, err = pcall(function()
			JoinObservable.createJoinObservable = function(leftStream, rightStream, opts)
				capturedOpts = opts
				return originalCreate(leftStream, rightStream, opts)
			end

			local joined = Query.from(left, "left")
				:leftJoin(right, "right")
				:using({
					left = { field = "id", bufferSize = 1 },
					right = { field = "id", bufferSize = 5 },
				})
				:joinWindow({ count = 10 })

			joined:subscribe(function() end)

			leftSubject:onCompleted()
			rightSubject:onCompleted()

			assert.is_table(capturedOpts)
			assert.are.equal(1, capturedOpts.perKeyBufferSizeLeft)
			assert.are.equal(5, capturedOpts.perKeyBufferSizeRight)
		end)

		restore()
		if not ok then
			error(err)
		end
	end)

	it("exposes a stable describe plan", function()
		local left = SchemaHelpers.observableFromTable("left", { { id = 1 } })
		local right = SchemaHelpers.observableFromTable("right", { { id = 2 } })

	local plan = Query.from(left, "left")
		:leftJoin(right, "right")
		:using({ left = { field = "id" }, right = { field = "id" } })
		:joinWindow({ count = 5 })
		:selectSchemas({ left = "L", right = "R" })
		:describe()

		assert.are.same({
			from = { "left" },
			joins = {
				{
					type = "left",
					source = "right",
					key = { map = { left = "id", right = "id" } },
					joinWindow = { mode = "count", count = 5 },
				},
			},
			select = { left = "L", right = "R" },
			gc = {
				mode = "count",
				count = 5,
				gcOnInsert = true,
			},
		}, plan)
	end)

	it("applies a per-query default join window when a step omits joinWindow", function()
		local leftSubject, left = SchemaHelpers.subjectWithSchema("left", { idField = "id" })
		local rightSubject, right = SchemaHelpers.subjectWithSchema("right", { idField = "id" })

		local capturedOpts
		local originalCreate = JoinObservable.createJoinObservable
		local function restore()
			JoinObservable.createJoinObservable = originalCreate
		end

		local ok, err = pcall(function()
			JoinObservable.createJoinObservable = function(leftStream, rightStream, opts)
				capturedOpts = opts
				return originalCreate(leftStream, rightStream, opts)
			end

			local joined = Query.from(left, "left")
				:withDefaultJoinWindow({
					time = 7,
					field = "sourceTime",
					currentFn = function()
						return 42
					end,
					gcOnInsert = false,
					gcIntervalSeconds = 1,
				})
				:leftJoin(right, "right")
				:using({ left = { field = "id" }, right = { field = "id" } })

			local plan = joined:describe()
			assert.are.same({ "left" }, plan.from)
			assert.are.same(
				{ mode = "time", time = 7, field = "sourceTime" },
				plan.joins[1].joinWindow
			)
			assert.are.equal("time", plan.gc.mode)
			assert.are.equal(7, plan.gc.time)
			assert.are.equal("sourceTime", plan.gc.field)
			assert.are.equal(false, plan.gc.gcOnInsert)
			assert.are.equal(1, plan.gc.gcIntervalSeconds)

			joined:subscribe(function() end)
			leftSubject:onCompleted()
			rightSubject:onCompleted()

			assert.is_table(capturedOpts)
			assert.are.equal("interval", capturedOpts.joinWindow.mode)
			assert.are.equal(7, capturedOpts.joinWindow.offset)
			assert.are.equal("sourceTime", capturedOpts.joinWindow.field)
			assert.are.equal(false, capturedOpts.gcOnInsert)
			assert.are.equal(1, capturedOpts.gcIntervalSeconds)
			assert.is_function(capturedOpts.joinWindow.currentFn)
		end)

		restore()
		if not ok then
			error(err)
		end
	end)

	it("describes additional join strategies (right/outer/anti)", function()
		local left = SchemaHelpers.observableFromTable("left", { { id = 1 } })
		local right = SchemaHelpers.observableFromTable("right", { { id = 1 } })

		local rightPlan = Query.from(left, "left")
			:rightJoin(right, "right")
			:using({ left = { field = "id" }, right = { field = "id" } })
			:describe()
		assert.are.equal("right", rightPlan.joins[1].type)

		local outerPlan = Query.from(left, "left")
			:outerJoin(right, "right")
			:using({ left = { field = "id" }, right = { field = "id" } })
			:describe()
		assert.are.equal("outer", outerPlan.joins[1].type)

		local antiPlan = Query.from(left, "left")
			:antiLeftJoin(right, "right")
			:using({ left = { field = "id" }, right = { field = "id" } })
			:describe()
		assert.are.equal("anti_left", antiPlan.joins[1].type)
	end)

	it("consumes matched pairs when oneShot is set", function()
		local leftSubject, left = SchemaHelpers.subjectWithSchema("left", { idField = "id" })
		local rightSubject, right = SchemaHelpers.subjectWithSchema("right", { idField = "id" })

		local joined = Query.from(left, "left")
			:innerJoin(right, "right")
			:using({
				left = { field = "id", oneShot = true },
				right = { field = "id", oneShot = true },
			})

		local results = {}
		local expired = {}
		joined:subscribe(function(result)
			results[#results + 1] = result
		end)
		joined:expired():subscribe(function(packet)
			expired[#expired + 1] = packet.reason
		end)

		leftSubject:onNext({ id = 1 })
		rightSubject:onNext({ id = 1 }) -- first match consumes both
		rightSubject:onNext({ id = 1 }) -- buffered until next left
		leftSubject:onNext({ id = 1 }) -- second arrival on each side

		assert.are.equal(2, #results)
		-- Consume-on-match should emit expirations when pairs are consumed.
		assert.is_true(#expired >= 2)
	end)
end)
