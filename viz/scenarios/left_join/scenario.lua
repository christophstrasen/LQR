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
		startOffset = 100,
	},
	layerOrder = { "inner", "outer" },
	layers = {
		inner = { fadeMultiplier = 2 },
		outer = { fadeMultiplier = 3 },
	},
	colors = {
		joined = { 0, 1, 0, 1.0 },
		expired = { 1, 0, 0, 1.0 },
	},
}

local function fadeSecondsFromTTL(ttl, multiplier)
	if not ttl then
		return nil
	end
	return ttl * (multiplier or 1)
end

local function columnMajorIdMapper(id, state)
	if type(id) ~= "number" then
		return nil, nil
	end
	-- Anchor at startOffset and fill down a column before moving right.
	local startOffset = windowConfig.startOffset or windowConfig.grid.startOffset or 0
	local offset = math.max(0, math.floor(id - startOffset))
	local row = (offset % state.rows) + 1
	local col = math.floor(offset / state.rows) + 1
	if col > state.columns then
		col = ((col - 1) % state.columns) + 1
	end
	return col, row
end

windowConfig.idMapper = columnMajorIdMapper
windowConfig.layers.inner.idMapper = columnMajorIdMapper
windowConfig.layers.outer.idMapper = columnMajorIdMapper
windowConfig.startOffset = 100

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

local ttl = joins[1].expirationWindow and joins[1].expirationWindow.ttl
local innerMultiplier = windowConfig.layers.inner.fadeMultiplier or 1
local outerMultiplier = windowConfig.layers.outer.fadeMultiplier or 1
windowConfig.layers.inner.fadeSeconds = fadeSecondsFromTTL(ttl, innerMultiplier)
	or windowConfig.layers.inner.fadeSeconds
windowConfig.layers.outer.fadeSeconds = fadeSecondsFromTTL(ttl, outerMultiplier)
	or windowConfig.layers.outer.fadeSeconds

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
			idMapper = windowConfig.idMapper,
			startOffset = windowConfig.startOffset,
			layerOrder = windowConfig.layerOrder or { "inner", "outer" },
			layers = {
				inner = {
					fadeSeconds = windowConfig.layers.inner.fadeSeconds,
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
					fadeSeconds = windowConfig.layers.outer.fadeSeconds,
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
