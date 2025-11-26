local package = require("package")
package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require("bootstrap")

local Query = require("Query")
local SchemaHelpers = require("tests.support.schema_helpers")
local Log = require("util.log").withTag("demo")

-- Minimal headless demo: build a grouped aggregate, re-ingest it into a second query, and log alerts.
local function buildDemo()
	local customersSubject, customers = SchemaHelpers.subjectWithSchema("customers", { idField = "id" })
	local ordersSubject, orders = SchemaHelpers.subjectWithSchema("orders", { idField = "id" })

	local grouped = Query.from(customers, "customers")
		:leftJoin(orders, "orders")
		:on({ customers = "id", orders = "customerId" })
		:groupBy("orders_per_customer", function(row)
			return row.customers.id
		end)
		:groupWindow({ count = 3 })
		:aggregates({ count = true, sum = { "orders.total" } })

	-- Log grouped aggregates so we see what flows into the second query.
	grouped:subscribe(function(g)
		local sumBucket = g.orders and g.orders._sum
		local sum = sumBucket and sumBucket.total or 0
		print(string.format("[grouped] schema=%s key=%s count=%s sum=%s", tostring(g.RxMeta.schema), tostring(g.RxMeta.groupKey), tostring(g._count), tostring(sum)))
	end)

	-- Re-ingest the aggregate stream as a new schema and filter on the aggregated fields.
	local alerts = Query.from(grouped, {
		schema = "orders_per_customer",
		resetTime = true, -- reset sourceTime to now so join windows in the new query treat it as fresh
	})
		:where(function(row)
			local agg = row.orders_per_customer
			local count = agg and agg._count or 0
			local sumBucket = agg and agg.orders and agg.orders._sum
			local sum = sumBucket and sumBucket.total or 0
			return count >= 2 and sum >= 50
		end)

	alerts:subscribe(function(row)
		local sum = row.orders_per_customer.orders._sum.total
		Log:info("[alert] customer=%s count=%s sum=%s", tostring(row.orders_per_customer.RxMeta.groupKey), row.orders_per_customer._count, sum)
		print(string.format("[alert] customer=%s count=%s sum=%s", tostring(row.orders_per_customer.RxMeta.groupKey), tostring(row.orders_per_customer._count), tostring(sum)))
	end)

	return {
		subjects = {
			customers = customersSubject,
			orders = ordersSubject,
		},
		run = function()
			customersSubject:onNext({ id = 1, name = "Ada", sourceTime = 0 })
			ordersSubject:onNext({ id = 10, customerId = 1, total = 30, sourceTime = 0 })
			ordersSubject:onNext({ id = 11, customerId = 1, total = 25, sourceTime = 0 })
			ordersSubject:onNext({ id = 12, customerId = 1, total = 5, sourceTime = 0 })
		end,
	}
end

local demo = buildDemo()
demo.run()

return demo
