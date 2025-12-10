local package = require("package")
package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require("LQR.bootstrap")

local Query = require("LQR.Query")
local SchemaHelpers = require("tests.support.schema_helpers")

---@diagnostic disable: undefined-global
describe("Query.distinct", function()
	it("drops duplicate records per schema key within the window", function()
		local lionsSubject, lions = SchemaHelpers.subjectWithSchema("lions", { idField = "id" })

		local seen, expired = {}, {}
	local query = Query.from(lions, "lions")
		:distinct("lions", { by = "id" })

	query:subscribe(function(row)
		seen[#seen + 1] = row:get("lions")
	end)
	query:expired():subscribe(function(packet)
		expired[#expired + 1] = packet
	end)

		lionsSubject:onNext({ id = 1, sourceTime = 1 })
		lionsSubject:onNext({ id = 1, sourceTime = 2 }) -- duplicate id suppressed
		lionsSubject:onNext({ id = 2, sourceTime = 3 })
		lionsSubject:onCompleted()

		assert.are.equal(2, #seen)
		assert.are.equal(1, seen[1].id)
		assert.are.equal(2, seen[2].id)
	local reasons = {}
	for i = 1, #expired do
		reasons[expired[i].reason] = (reasons[expired[i].reason] or 0) + 1
	end
	assert.is_true((reasons["distinct_schema"] or 0) >= 1)
	end)

	it("re-admits a key after it expires from a time window", function()
		local now = 0
		local lionsSubject, lions = SchemaHelpers.subjectWithSchema("lions", { idField = "id" })
		local seen = {}

	Query.from(lions, "lions")
		:distinct("lions", {
			by = "id",
				window = { mode = "time", field = "sourceTime", offset = 5, currentFn = function()
					return now
				end },
			})
			:subscribe(function(row)
				seen[#seen + 1] = row:get("lions")
			end)

		lionsSubject:onNext({ id = 1, sourceTime = 0 })
		now = 10 -- beyond the offset, so the key should expire
		lionsSubject:onNext({ id = 1, sourceTime = 10 })

		assert.are.equal(2, #seen)
	end)

	it("handles join results when distinct is placed after a join", function()
		local lionsSubject, lions = SchemaHelpers.subjectWithSchema("lions", { idField = "id" })
		local gazellesSubject, gazelles = SchemaHelpers.subjectWithSchema("gazelles", { idField = "id" })
		local results = {}

		Query.from(lions, "lions")
			:innerJoin(gazelles, "gazelles")
			:using({
				lions = { field = "location" },
				gazelles = { field = "location" },
			})
			:distinct("lions", { by = "id" })
			:subscribe(function(result)
				results[#results + 1] = result
			end)

		lionsSubject:onNext({ id = 1, location = "Glade", sourceTime = 1 })
		gazellesSubject:onNext({ id = 10, location = "Glade", sourceTime = 1 }) -- first join emission
		lionsSubject:onNext({ id = 1, location = "Glade", sourceTime = 2 }) -- duplicate lions id; should be suppressed

		lionsSubject:onCompleted()
		gazellesSubject:onCompleted()

		assert.are.equal(1, #results)
		local lionsRow = results[1]:get("lions")
		assert.are.equal(1, lionsRow.id)
	end)
end)
