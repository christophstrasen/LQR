local package = require("package")
package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require('LQR.bootstrap')

local rx = require("reactivex")
local Query = require("Query")
local Result = require("JoinObservable.result")

---@diagnostic disable: undefined-global
describe("Query rewrap of grouped outputs", function()
	it("adapts group_aggregate into a join_result with id and reset time", function()
		local subject = rx.Subject.create()
		local now = 123
		local bucket = {}

		local builder = Query.from(subject, {
			schema = "agg_schema",
			resetTime = true,
			timeField = "sourceTime",
			currentFn = function()
				return now
			end,
		})

		builder:into(bucket):subscribe()

			subject:onNext({
				_count_all = 1,
				sourceTime = 1,
				RxMeta = {
					schema = "orders_grouped",
					shape = "group_aggregate",
				groupKey = "g1",
				groupName = "orders_grouped",
			},
		})

		assert.is_true(getmetatable(bucket[1]) == Result)
		local payload = bucket[1]:get("agg_schema")
		assert.is_table(payload)
		assert.are.equal("g1", payload.RxMeta.id)
		assert.are.equal(now, payload.sourceTime)
	end)

	it("adapts group_enriched into a join_result exposing contained schemas", function()
		local subject = rx.Subject.create()
		local bucket = {}

		Query.from(subject):into(bucket):subscribe()

			subject:onNext({
				_count_all = 2,
				RxMeta = {
					shape = "group_enriched",
					groupKey = "k1",
					groupName = "animals",
				},
				animals = {
					value = 5,
					RxMeta = { schema = "animals", id = 7 },
				},
				["_groupBy:animals"] = {
					_count_all = 2,
					RxMeta = {
						schema = "_groupBy:animals",
						groupKey = "k1",
						groupName = "animals",
				},
			},
		})

		assert.is_true(getmetatable(bucket[1]) == Result)
		assert.are.equal(5, bucket[1]:get("animals").value)
		assert.are.equal(7, bucket[1]:get("animals").RxMeta.id)
		assert.are.equal("k1", bucket[1]:get("_groupBy:animals").RxMeta.id)
	end)
end)

describe("Query rewrap from builder sources", function()
	it("accepts a grouped builder as source", function()
		local subject, source = require("tests.support.schema_helpers").subjectWithSchema("schema", { idField = "id" })
		local aggregate = Query.from(source)
		local grouped = aggregate:groupBy("grouped", function(row)
			return row.schema.id
		end):aggregates({ row_count = true })

		local bucket = {}
		Query.from(grouped):into(bucket):subscribe()

		subject:onNext({ id = 1 })
		assert.is_true(#bucket >= 1)
	end)

	it("rewraps group_enriched with schema override and resetTime", function()
		local subject = rx.Subject.create()
		local now = 999
		local bucket = {}

		Query.from(subject, {
			schema = "enriched_stream",
			resetTime = true,
			timeField = "sourceTime",
			currentFn = function()
				return now
			end,
		}):into(bucket):subscribe()

			subject:onNext({
				_count_all = 2,
				sourceTime = 1,
				RxMeta = {
					shape = "group_enriched",
					groupKey = "gk",
					groupName = "animals",
			},
			animals = {
				value = 5,
				RxMeta = { schema = "animals", id = 7 },
			},
			["_groupBy:animals"] = {
				_count = 2,
				RxMeta = {
					schema = "_groupBy:animals",
					groupKey = "gk",
					groupName = "animals",
				},
			},
		})

		local res = bucket[1]
		assert.is_true(getmetatable(res) == Result)
		assert.are.equal(now, res:get("animals").sourceTime)
		assert.are.equal("animals", res.RxMeta.schemaMap["animals"].schema)
	end)

	it("honors idField override when rewrapping grouped aggregate", function()
		local subject = rx.Subject.create()
		local bucket = {}

		Query.from(subject, {
			schema = "agg_schema",
			idField = "customId",
		}):into(bucket):subscribe()

		subject:onNext({
			customId = "cid-1",
			RxMeta = {
				shape = "group_aggregate",
				groupKey = "g1",
				groupName = "agg_schema",
			},
		})

		local payload = bucket[1]:get("agg_schema")
		assert.are.equal("cid-1", payload.RxMeta.id)
		assert.are.equal("customId", payload.RxMeta.idField)
	end)
end)
