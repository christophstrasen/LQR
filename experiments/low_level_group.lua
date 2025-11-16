local package = require("package")
package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require("bootstrap")

local rx = require("reactivex")
local Group = require("groupByObservable")

local source = rx.Subject.create()

local aggregates, enriched, expired = Group.createGroupByObservable(source, {
	keySelector = function(row)
		return row.key
	end,
	groupName = "demo",
	window = { count = 2 }, -- or { time = 5, field = "ts", gcIntervalSeconds = 1 }
	aggregates = {
		sum = { "schema.value" },
		avg = { "schema.value" },
	},
})

print("head", "key", "count", "sum", "avg", "schema")

aggregates:subscribe(function(row)
	print("[agg]", row.key, row._count, row.schema._sum.value, row.schema._avg.value, row.RxMeta.schema)
end)
print("head", "count", "value", "sum", "avg")
enriched:subscribe(function(row)
	print("[enr]", row._count, row.schema.value, row.schema._sum.value, row.schema._avg.value)
end)
print("head", "count", "value", "sum", "avg")
expired:subscribe(function(ev)
	print("[exp]", ev.key, ev.reason, ev.time or "n/a")
end)

source:onNext({ key = "k1", schema = { value = 10 } })
source:onNext({ key = "k1", schema = { value = 20 } })
source:onNext({ key = "k1", schema = { value = 30 } })
