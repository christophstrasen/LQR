local package = require("package")
package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require("bootstrap")

local Query = require("Query")
local JoinObservable = require("JoinObservable")
local SchemaHelpers = require("tests.support.schema_helpers")

---@diagnostic disable: undefined-global
describe("Join high-level facade", function()
	after_each(function()
		JoinObservable.setWarningHandler()
	end)

	local function collect(resultStream)
		local buffer = {}
		resultStream:subscribe(function(value)
			buffer[#buffer + 1] = value
		end)
		return buffer
	end

	it("warns when onField is missing on incoming records", function()
		local warnings = {}
		JoinObservable.setWarningHandler(function(message)
			warnings[#warnings + 1] = message
		end)

		local leftSubject, left = SchemaHelpers.subjectWithSchema("left", { idField = "id" })
		local rightSubject, right = SchemaHelpers.subjectWithSchema("right", { idField = "id" })

		local joined = Query.from(left, "left")
			:innerJoin(right, "right")
			:onField("customerId")

		local results = collect(joined)

		leftSubject:onNext({ id = 1 })
		rightSubject:onNext({ id = 10 })
		leftSubject:onCompleted()
		rightSubject:onCompleted()

		assert.are.equal(0, #results)
		assert.is_true(#warnings > 0)
	end)

	it("raises configuration errors when onSchemas lacks coverage for known schemas", function()
		local left = SchemaHelpers.observableFromTable("left", { { id = 1 } })
		local right = SchemaHelpers.observableFromTable("right", { { id = 1 } })

		assert.has_error(function()
			Query.from(left, "left")
				:innerJoin(right, "right")
				:onSchemas({ left = "id" }) -- missing right
		end)
	end)

	it("auto-chains JoinResults into subsequent joins", function()
		local customersSubject, customers = SchemaHelpers.subjectWithSchema("customers", { idField = "id" })
		local ordersSubject, orders = SchemaHelpers.subjectWithSchema("orders", { idField = "id" })
		local refundsSubject, refunds = SchemaHelpers.subjectWithSchema("refunds", { idField = "id" })

		local joined = Query.from(customers, "customers")
			:leftJoin(orders, "orders")
			:onSchemas({ customers = "id", orders = "customerId" })
			:innerJoin(refunds, "refunds")
			:onSchemas({ orders = "id", refunds = "orderId" })
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
			:onId()
			:window({ count = 1 })

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

	it("exposes a stable describe plan", function()
		local left = SchemaHelpers.observableFromTable("left", { { id = 1 } })
		local right = SchemaHelpers.observableFromTable("right", { { id = 2 } })

		local plan = Query.from(left, "left")
			:leftJoin(right, "right")
			:onId()
			:window({ count = 5 })
			:selectSchemas({ left = "L", right = "R" })
			:describe()

		assert.are.same({
			from = { "left" },
			joins = {
				{
					type = "left",
					source = "right",
					key = "RxMeta.id",
					window = { mode = "count", count = 5 },
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
end)
