local customers = require("viz.scenarios.left_join.customers")
local orders = require("viz.scenarios.left_join.orders")

local Profiles = {}

Profiles.customers = {
	name = "customers",
	color = { 0.23, 0.45, 0.95, 1.0 },
	observable = "customers",
	tracks = {
		{ field = "id" },
	},
	hoverFields = {
		"id",
		"name",
	},
	meta = { schema = { constant = "customers" } },
	data = customers,
	stream = {
		schema = "customers",
		idField = "id",
		color = { 0.23, 0.45, 0.95, 1.0 },
		delay = { minDelay = 0.0041, maxDelay = 0.05, mode = "ordered" },
		records = customers,
	},
}

Profiles.orders = {
	name = "orders",
	color = { 0.95, 0.83, 0.25, 1.0 },
	observable = "orders",
	tracks = {
		{ field = "customerId" },
	},
	hoverFields = {
		"orderId",
		"customerId",
		"total",
	},
	meta = { schema = { constant = "orders" } },
	data = orders,
	stream = {
		schema = "orders",
		idField = "orderId",
		color = { 0.95, 0.83, 0.25, 1.0 },
		delay = { minDelay = 0.031, maxDelay = 0.08, mode = "jittered" },
		records = orders,
	},
}

Profiles.streams = {
	customers = Profiles.customers.stream,
	orders = Profiles.orders.stream,
}

return Profiles
