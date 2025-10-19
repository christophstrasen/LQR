-- Shared helpers to build demo query sources and emit deterministic events.
local DemoData = {}

local Query = require("Query")
local SchemaHelpers = require("tests.support.schema_helpers")

local function buildSubjects()
	local customersSubject, customers = SchemaHelpers.subjectWithSchema("customers", { idField = "id" })
	local ordersSubject, orders = SchemaHelpers.subjectWithSchema("orders", { idField = "id" })
	local refundsSubject, refunds = SchemaHelpers.subjectWithSchema("refunds", { idField = "id" })

	local builder = Query.from(customers, "customers")
		:leftJoin(orders, "orders")
		:onSchemas({ customers = "id", orders = "customerId" })
		:leftJoin(refunds, "refunds")
		:onSchemas({ orders = "id", refunds = "orderId" })
		:window({ count = 10 })

	return {
		builder = builder,
		subjects = {
			customers = customersSubject,
			orders = ordersSubject,
			refunds = refundsSubject,
		},
	}
end

local BASELINE_EVENTS = {
	{ schema = "customers", payload = { id = 10, name = "Ada" } },
	{ schema = "orders", payload = { id = 101, customerId = 10 } },
	{ schema = "refunds", payload = { id = 201, orderId = 101 } },
	{ schema = "customers", payload = { id = 40, name = "Zed" } }, -- unmatched to trigger expires
	{ schema = "customers", payload = { id = 50, name = "Bob" } },
	{ schema = "orders", payload = { id = 102, customerId = 50 } },
	{ schema = "customers", payload = { id = 90, name = "Cara" } },
	{ schema = "orders", payload = { id = 103, customerId = 90 } },
}

function DemoData.build()
	return buildSubjects()
end

function DemoData.emitBaseline(subjects)
	for _, event in ipairs(BASELINE_EVENTS) do
		local subject = subjects[event.schema]
		assert(subject, string.format("Unknown schema %s in demo events", tostring(event.schema)))
		subject:onNext(event.payload)
	end
end

function DemoData.complete(subjects)
	for _, subject in pairs(subjects or {}) do
		if subject.onCompleted then
			subject:onCompleted()
		end
	end
end

return DemoData
