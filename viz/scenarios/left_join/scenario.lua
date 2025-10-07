local customers = require("viz.scenarios.left_join.customers")
local orders = require("viz.scenarios.left_join.orders")
local ConfigUtils = require("viz.config_utils")

local Scenario = {}

local windowConfig = {
	grid = {
		columns = 20,
		rows = 20,
		cellSize = 36,
		padding = 5,
		startOffset = 90,
	},
	layerOrder = { "inner", "outer" },
	layers = {
		inner = { fadeSeconds = 10 },
		outer = { fadeSeconds = 10 },
	},
	colors = {
		joined = { 0, 1, 0, 1.0 },
		expired = { 1, 0, 0, 1.0 },
	},
}

local streams = {
	customers = {
		schema = "customers",
		idField = "id",
		color = { 0.23, 0.45, 0.95, 1.0 },
		delay = { minDelay = 0.001, maxDelay = 0.1 },
		records = customers,
	},
	orders = {
		schema = "orders",
		idField = "orderId",
		color = { 0.95, 0.83, 0.25, 1.0 },
		delay = { minDelay = 0.01, maxDelay = 0.2 },
		records = orders,
	},
}

local joins = {
	{
		name = "customersWithOrders",
		expiredName = "expired",
		left = "customers",
		right = "orders",
		on = {
			customers = "id",
			orders = "customerId",
		},
		joinType = "left",
		expirationWindow = {
			mode = "time",
			ttl = 60,
			field = "sourceTime",
			currentFn = os.time,
		},
	},
}

local data = {
	customers = customers,
	orders = orders,
	window = windowConfig,
	streams = streams,
	joins = joins,
}

data.minCustomerId = ConfigUtils.minFieldValue(customers, "id")

Scenario.data = data

local function streamColor(name)
	local stream = streams[name]
	return stream and stream.color
end

local function resolveObservable(observables, name, fallback)
	if name and observables[name] then
		return observables[name]
	end
	if fallback then
		return observables[fallback]
	end
	return nil
end

local function identity(value)
	return value
end

function Scenario.buildRecipe(observables)
	local joinConfig = joins[1] or {}
	local joinedObservable = resolveObservable(observables, joinConfig.name or joinConfig.resultName, "customersWithOrders")
	local expiredObservable = resolveObservable(observables, joinConfig.expiredName, "expired")
	local colors = windowConfig.colors or {}
	local layerDefaults = windowConfig.layers or {}

	return {
		window = {
			grid = windowConfig.grid or {},
			layerOrder = windowConfig.layerOrder or { "inner", "outer" },
			layers = {
				inner = {
					fadeSeconds = (layerDefaults.inner and layerDefaults.inner.fadeSeconds) or 10,
					streams = {
						{
							name = "customers",
							color = streamColor("customers"),
							observable = observables.customers,
							track_field = "id",
							hoverFields = {
								"id",
								"name",
								{ key = "record", fn = identity },
							},
							meta = { schema = { constant = "customers" } },
						},
						{
							name = "orders",
							color = streamColor("orders"),
							observable = observables.orders,
							track_field = "customerId",
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
					fadeSeconds = (layerDefaults.outer and layerDefaults.outer.fadeSeconds) or 10,
					streams = {
						{
							name = "joined",
							color = colors.joined,
							observable = joinedObservable,
							tracks = {
								{ schema = "customers", field = "id" },
								{ schema = "orders", field = "customerId" },
							},
							hoverFields = {
								{ key = "match", field = "match" },
								{ key = "customer", field = "schemas.customers" },
								{ key = "order", field = "schemas.orders" },
							},
							meta = { schema = "schema" },
						},
						{
							name = "expired",
							color = colors.expired,
							observable = expiredObservable,
							tracks = {
								{ schema = "customers", field = "id" },
								{ schema = "orders", field = "customerId" },
								{ schema = "orders", field = "id" },
							},
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
		},
	}
end

return Scenario
