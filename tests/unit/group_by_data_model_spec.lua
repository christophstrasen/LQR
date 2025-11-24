local package = require("package")
package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require("bootstrap")

local DataModel = require("groupByObservable.data_model")

---@diagnostic disable: undefined-global
describe("GroupBy data model", function()
	it("builds aggregate rows with prefixed aggregates and _count", function()
		local aggregate = DataModel.buildAggregateRow({
			groupName = "battle",
			key = "battle:zone42",
			aggregates = {
				count = 7,
				sum = {
					["battle.combat.damage"] = 81,
					["battle.healing.received"] = 124,
				},
				avg = {
					["battle.combat.damage"] = 13.5,
				},
			},
				window = { start = 1, ["end"] = 2 },
		})

		assert.are.equal(7, aggregate._count)
		assert.are.same({
			schema = "battle",
			groupKey = "battle:zone42",
			groupName = "battle",
			view = "aggregate",
		}, aggregate.RxMeta)
		assert.are.equal(81, aggregate.battle.combat._sum.damage)
		assert.are.equal(13.5, aggregate.battle.combat._avg.damage)
		assert.are.equal(124, aggregate.battle.healing._sum.received)
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
				count = 2,
				sum = {
					["battle.combat.damage"] = 81,
					["customers.age"] = 222,
				},
				avg = {
					["battle.combat.damage"] = 40.5,
					["customers.age"] = 37,
				},
			},
		})

		assert.are.equal(2, enriched._count)
		assert.are.same({
			schema = "battle",
			groupKey = "k1",
			groupName = "battle",
			view = "enriched",
		}, enriched.RxMeta)

		-- preserves original fields
		assert.are.equal(10, enriched.battle.combat.damage)

		-- adds aggregates under schemas, creating missing schemas as needed
		assert.are.equal(81, enriched.battle.combat._sum.damage)
		assert.are.equal(40.5, enriched.battle.combat._avg.damage)
		assert.are.equal(222, enriched.customers._sum.age)
		assert.are.equal(37, enriched.customers._avg.age)

		-- synthetic schema for grouping
		assert.is_table(enriched["_groupBy:battle"])
		assert.are.equal(2, enriched["_groupBy:battle"]._count)
		assert.are.same({
			schema = "battle",
			groupKey = "k1",
			groupName = "battle",
			view = "enriched",
		}, enriched["_groupBy:battle"].RxMeta)
		assert.are.equal(81, enriched["_groupBy:battle"].battle.combat._sum.damage)
	end)
end)
