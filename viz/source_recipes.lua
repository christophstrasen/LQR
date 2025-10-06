local Observables = require("viz.observables")

local function customerLabel(record)
	return ("Customer %s"):format(record.name or record.id)
end

local function orderLabel(record)
	return string.format("Order %s → %s", record.orderId, record.customerId)
end

local function identity(value)
	return value
end

local Config = {}

Config.window = {
	grid = {
		columns = 20,
		rows = 20,
		cellSize = 36,
		padding = 5,
		startOffset = 90,
	},
	layerOrder = { "inner", "outer" },
	layers = {
		inner = {
			fadeSeconds = 10,
			streams = {
				{
					name = "customers",
					color = { 0.23, 0.45, 0.95, 1.0 },
					observable = Observables.customers,
					track_field = "id",
					label = customerLabel,
					hoverFields = {
						"id",
						"name",
						{ key = "record", fn = identity },
					},
					meta = { schema = { constant = "customers" } },
				},
				{
					name = "orders",
					color = { 0.95, 0.83, 0.25, 1.0 },
					observable = Observables.orders,
					track_field = "customerId",
					label = orderLabel,
					hoverFields = {
						"orderId",
						"customerId",
						"total",
						{ key = "record", fn = identity },
					},
					meta = { schema = { constant = "orders" } },
				},
			},
		},
		outer = {
			fadeSeconds = 10,
			streams = {
				{
					name = "joined",
					color = { 0, 1, 0, 1.0 },
					observable = Observables.customersWithOrders,
					track_field = "id",
					track_schema = "customers",
					label = "label",
					hoverFields = {
						{ key = "match", field = "match" },
						{ key = "customer", field = "customer" },
						{ key = "order", field = "order" },
					},
					meta = { schema = "schema" },
				},
				{
					name = "expired",
					color = { 1, 0, 0, 1.0 },
					observable = Observables.expired,
					track_field = "id",
					label = function(record)
						return string.format("Expired %s", record.schema or "record")
					end,
					hoverFields = {
						{ key = "schema", field = "schema" },
						{ key = "reason", field = "reason" },
						{ key = "record", field = "record" },
						{ key = "expired", constant = true },
					},
					meta = { schema = "schema" },
				},
			},
		},
	},
}

return Config
