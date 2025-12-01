local package = require("package")
package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require('LQR.bootstrap')

local DataModel = require("groupByObservable.data_model")

---@diagnostic disable: undefined-global
describe("GroupBy data model", function()
	it("builds aggregate rows with prefixed aggregates and _count", function()
		local aggregate = DataModel.buildAggregateRow({
			groupName = "battle",
			key = "battle:zone42",
			aggregates = {
				row_count = 7,
				count = {
					["battle.id"] = 7,
				},
				sum = {
					["battle.combat.damage"] = 81,
					["battle.healing.received"] = 124,
				},
				avg = {
					["battle.combat.damage"] = 13.5,
				},
				aliases = {
					["battle.avgDamage"] = 13.5,
				},
			},
				window = { start = 1, ["end"] = 2 },
		})

		assert.are.equal(7, aggregate._count_all)
		assert.are.equal("battle:zone42", aggregate._group_key)
		assert.are.equal(7, aggregate.battle._count.id)
		assert.are.equal(7, aggregate._count.battle)
		assert.are.same({
			schema = "battle",
			groupKey = "battle:zone42",
			groupName = "battle",
			view = "aggregate",
			shape = "group_aggregate",
		}, aggregate.RxMeta)
		assert.are.equal(81, aggregate.battle.combat._sum.damage)
		assert.are.equal(13.5, aggregate.battle.combat._avg.damage)
		assert.are.equal(124, aggregate.battle.healing._sum.received)
		assert.are.equal(13.5, aggregate.battle.avgDamage)
		assert.are.same({ start = 1, ["end"] = 2 }, aggregate.window)
	end)

	it("enriches rows in place and creates missing schemas", function()
		local row = {
			battle = {
				combat = { damage = 10 },
			},
		}

		local enriched = DataModel.buildEnrichedRow(row, {
			groupName = "battle",
			key = "k1",
			aggregates = {
				row_count = 2,
				count = {
					["battle.combat.damage"] = 2,
					["customers.id"] = 2,
				},
				sum = {
					["battle.combat.damage"] = 81,
					["customers.age"] = 222,
				},
				avg = {
					["battle.combat.damage"] = 40.5,
					["customers.age"] = 37,
				},
				aliases = {
					["battle.combat.avgDamageAlias"] = 40.5,
					["customers.ageAverage"] = 37,
				},
			},
		})

		assert.are.equal(2, enriched._count_all)
		assert.are.same({
			schema = "battle",
			groupKey = "k1",
			groupName = "battle",
			view = "enriched",
			shape = "group_enriched",
		}, enriched.RxMeta)
		assert.are.equal("k1", enriched._group_key)

		-- preserves original fields
		assert.are.equal(10, enriched.battle.combat.damage)

		-- adds aggregates under schemas, creating missing schemas as needed
		assert.are.equal(81, enriched.battle.combat._sum.damage)
		assert.are.equal(40.5, enriched.battle.combat._avg.damage)
		assert.are.equal(222, enriched.customers._sum.age)
		assert.are.equal(37, enriched.customers._avg.age)
		assert.are.equal(40.5, enriched.battle.combat.avgDamageAlias)
		assert.are.equal(37, enriched.customers.ageAverage)

		-- synthetic schema for grouping
		assert.is_table(enriched["_groupBy:battle"])
			assert.are.equal(2, enriched["_groupBy:battle"]._count_all)
			assert.are.equal("k1", enriched["_groupBy:battle"]._group_key)
		assert.are.same({
			schema = "battle",
			groupKey = "k1",
			groupName = "battle",
			view = "enriched",
			shape = "group_enriched",
			}, enriched["_groupBy:battle"].RxMeta)
			assert.are.equal(81, enriched["_groupBy:battle"].battle.combat._sum.damage)
			assert.are.equal(2, enriched.battle.combat._count.damage)
			assert.are.equal(2, enriched._count.battle)
		end)
	end)
