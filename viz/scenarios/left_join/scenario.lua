local rx = require("reactivex")
local Profiles = require("viz.scenarios.left_join.profiles")
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
		inner = { fadeSeconds = 6 },
		outer = { fadeSeconds = 12 },
	},
	colors = {
		joined = { 0, 1, 0, 1.0 },
		expired = { 1, 0, 0, 1.0 },
	},
}

local streams = Profiles.streams

local function loveScheduler(delaySeconds, fn)
	if os.getenv("DEBUG") == "1" then
		print(string.format("[viz] scheduling GC tick in %.3fs", delaySeconds or 0))
	end
	local sub = rx.scheduler.schedule(function()
		if os.getenv("DEBUG") == "1" then
			print("[viz] executing scheduled GC tick")
		end
		fn()
	end, delaySeconds or 0)
	return sub or {
		unsubscribe = function()
			if sub and sub.unsubscribe then
				sub:unsubscribe()
			end
		end,
	}
end

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
		joinType = "inner",
		expirationWindow = {
			mode = "time",
			ttl = 4,
			field = "sourceTime",
			currentFn = os.time,
		},
		gcIntervalSeconds = 2,
		gcOnInsert = true,
		gcScheduleFn = loveScheduler,
	},
}

local data = {
	window = windowConfig,
	streams = streams,
	joins = joins,
}

data.minCustomerId = ConfigUtils.minFieldValue(streams.customers.records, "id")

Scenario.data = data

function Scenario.buildRecipe(observables)
	local colors = windowConfig.colors or {}
	return {
		window = {
			grid = windowConfig.grid or {},
			layerOrder = windowConfig.layerOrder or { "inner", "outer" },
			layers = {
				inner = {
					fadeSeconds = 4.5,
					streams = {
						{
							name = Profiles.customers.name,
							color = Profiles.customers.color,
							observable = observables[Profiles.customers.observable],
							track_field = Profiles.customers.tracks[1].field,
							hoverFields = Profiles.customers.hoverFields,
							meta = Profiles.customers.meta,
						},
						{
							name = Profiles.orders.name,
							color = Profiles.orders.color,
							observable = observables[Profiles.orders.observable],
							track_field = Profiles.orders.tracks[1].field,
							hoverFields = Profiles.orders.hoverFields,
							meta = Profiles.orders.meta,
						},
					},
				},
				outer = {
					fadeSeconds = 20,
					streams = {
						{
							name = "joined",
							color = colors.joined,
							observable = observables.customersWithOrders,
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
							observable = observables.expired,
							tracks = {
								{ schema = "customers", field = "id" },
								{ schema = "orders", field = "customerId" },
								{ schema = "orders", field = "id" },
							},
							hoverFields = {
								{ key = "schema", field = "schema" },
								{ key = "reason", field = "reason" },
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
