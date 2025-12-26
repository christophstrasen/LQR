local package = require("package")
package.path = "./?.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require('LQR/bootstrap')

local rx = require("reactivex")
local Core = require("LQR/GroupByObservable/core")

---@diagnostic disable: undefined-global
describe("GroupByObservable core", function()
	it("groups with count window and emits aggregate + enriched", function()
		local source = rx.Subject.create()
		local aggregateStream, enrichedStream, expiredStream = Core.createGroupByObservable(source, {
			keySelector = function(row)
				return row.key
			end,
			window = { count = 2 },
			aggregates = {
				sum = { "schema.value" },
				avg = { "schema.value" },
			},
		})

		local aggregates = {}
		local enriched = {}
		local expired = {}

		aggregateStream:subscribe(function(row)
			aggregates[#aggregates + 1] = row
		end)
		enrichedStream:subscribe(function(row)
			enriched[#enriched + 1] = row
		end)
		expiredStream:subscribe(function(packet)
			expired[#expired + 1] = packet
		end)

		source:onNext({ key = "k1", schema = { value = 10 } })
		source:onNext({ key = "k1", schema = { value = 20 } })
		source:onNext({ key = "k1", schema = { value = 30 } })

		-- last aggregate reflects last two entries (20 + 30)
		local lastAgg = aggregates[#aggregates]
			assert.are.equal(2, lastAgg._count_all)
			assert.are.equal(50, lastAgg.schema._sum.value)
			assert.are.equal(25, lastAgg.schema._avg.value)
		assert.is_table(lastAgg.RxMeta)
		assert.are.equal("k1", lastAgg.RxMeta.groupKey)
		assert.are.equal("k1", lastAgg.RxMeta.groupName)
		assert.are.equal("group_aggregate", lastAgg.RxMeta.shape)

		-- last enriched mirrors aggregate values and keeps original field
		local lastEnriched = enriched[#enriched]
			assert.are.equal(2, lastEnriched._count_all)
			assert.are.equal(30, lastEnriched.schema.value)
			assert.are.equal(50, lastEnriched.schema._sum.value)
			assert.are.equal(25, lastEnriched.schema._avg.value)
		assert.are.equal("group_enriched", lastEnriched.RxMeta.shape)

		-- evicted oldest entry once window exceeded
		assert.are.equal(1, #expired)
		assert.are.equal("k1", expired[1].key)
	end)

	it("expires old entries with time window and periodic GC", function()
		local source = rx.Subject.create()
		local currentTime = 0
		local function now()
			return currentTime
		end

			local _, _, expiredStream = Core.createGroupByObservable(source, {
				keySelector = function(row)
					return row.key
				end,
				window = {
				time = 5,
					field = "ts",
					currentFn = now,
					gcIntervalSeconds = 1,
				},
				aggregates = {
					count = { "ts" },
				},
			})

		local expired = {}
		expiredStream:subscribe(function(packet)
			expired[#expired + 1] = packet
		end)

		source:onNext({ key = "k1", ts = 0 })
		source:onNext({ key = "k1", ts = 1 })

		-- Advance time so both should expire; trigger periodic GC by stepping scheduler
		currentTime = 10
		rx.scheduler.update(1)

		assert.are.equal(2, #expired)
		assert.are.equal("k1", expired[1].key)
		assert.are.equal("expired", expired[1].reason)
	end)

	it("supports distinctFn per aggregate and aliases results", function()
		local source = rx.Subject.create()
		local aggregateStream, enrichedStream = Core.createGroupByObservable(source, {
			keySelector = function(row)
				return row.key
			end,
			window = { count = 10 },
			aggregates = {
				count = {
					{
						path = "schema.id",
						distinctFn = function(row)
							return row.schema and row.schema.name
						end,
						alias = "distinctNames",
					},
				},
				avg = {
					{
						path = "schema.value",
						distinctFn = function(row)
							return row.schema and row.schema.name
						end,
						alias = "avgByName",
					},
				},
			},
		})

		local lastAgg
		local lastEnriched
		aggregateStream:subscribe(function(row)
			lastAgg = row
		end)
		enrichedStream:subscribe(function(row)
			lastEnriched = row
		end)

		source:onNext({ key = "k1", schema = { id = 1, name = "lion", value = 10 } })
		source:onNext({ key = "k1", schema = { id = 2, name = "lion", value = 30 } }) -- duplicate distinct key
		source:onNext({ key = "k1", schema = { id = 3, name = "gazelle", value = 50 } })

		assert.are.equal(2, lastAgg.schema._count.id)
		assert.are.equal(2, lastAgg.schema.distinctNames)
		assert.are.equal(30, lastAgg.schema._avg.value)
		assert.are.equal(30, lastAgg.schema.avgByName)

		assert.are.equal(2, lastEnriched.schema._count.id)
		assert.are.equal(2, lastEnriched.schema.distinctNames)
		assert.are.equal(30, lastEnriched.schema._avg.value)
		assert.are.equal(30, lastEnriched.schema.avgByName)
		assert.are.equal(2, lastEnriched["_groupBy:k1"].schema._count.id)
		assert.are.equal(30, lastEnriched["_groupBy:k1"].schema._avg.value)
	end)

	it("computes explicit count aggregates even when row_count is disabled", function()
		local source = rx.Subject.create()
		local aggregateStream, enrichedStream = Core.createGroupByObservable(source, {
			keySelector = function(row)
				return row.key
			end,
			window = { count = 10 },
			aggregates = {
				row_count = false,
				count = {
					{
						path = "schema.id",
						distinctFn = function(row)
							return row.schema and tostring(row.schema.id)
						end,
					},
				},
			},
		})

		local lastAgg
		local lastEnriched
		aggregateStream:subscribe(function(row)
			lastAgg = row
		end)
		enrichedStream:subscribe(function(row)
			lastEnriched = row
		end)

		source:onNext({ key = "k1", schema = { id = 1 } })
		source:onNext({ key = "k1", schema = { id = 2 } })

		-- `row_count=false` disables `_count_all` (group row count), but explicit count aggregates still compute.
		assert.are.equal(0, lastAgg._count_all)
		assert.are.equal(2, lastAgg.schema._count.id)

		assert.are.equal(0, lastEnriched._count_all)
		assert.are.equal(2, lastEnriched.schema._count.id)
	end)
end)
