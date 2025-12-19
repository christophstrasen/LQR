local package = require("package")
package.path = "./?.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require("LQR/bootstrap")

local rx = require("reactivex")
local LQR = require("LQR")
local Query = LQR.Query
local Schema = LQR.Schema

---@diagnostic disable: undefined-global
describe("LQR default currentFn override", function()
	after_each(function()
		Query.setDefaultCurrentFn(nil)
	end)

	it("uses Query.setDefaultCurrentFn for groupWindow time windows when currentFn is omitted", function()
		local now = 0
		Query.setDefaultCurrentFn(function()
			return now
		end)

		local source = rx.Subject.create()
		local events = Schema.wrap("events", source, {
			idField = "id",
			sourceTimeField = "ts",
		})

		local q = Query.from(events, "events")
			:groupByEnrich("_groupBy:test", function(row)
				return row.events.kind
			end)
			:groupWindow({
				time = 5,
				field = "events.RxMeta.sourceTime",
				gcOnInsert = true,
			})
			:aggregates({ row_count = true })

		local expired = {}
		q:expired():subscribe(function(packet)
			expired[#expired + 1] = packet
		end)

		-- Insert two entries at t=0 and t=1, then advance now and insert another one to trigger eviction.
		now = 1
		source:onNext({ id = 1, ts = 0, kind = "k1" })
		source:onNext({ id = 2, ts = 1, kind = "k1" })

		now = 10
		source:onNext({ id = 3, ts = 10, kind = "k1" })

		-- Old entries should have expired relative to now=10 and window=5.
		assert.is_true(#expired >= 2)
		assert.are.equal("group", expired[1].origin)
		assert.are.equal("k1", expired[1].key)
	end)
end)

