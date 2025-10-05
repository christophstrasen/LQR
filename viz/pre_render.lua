local rx = require("reactivex")
local Schema = require("JoinObservable.schema")
local JoinObservable = require("JoinObservable")

local Observable = rx.Observable or rx

local PreRender = {}

math.randomseed(os.time())

local DEFAULT_FADE_DURATION = 10 -- seconds to decay alpha from 100 to 0

local DataSources = require("viz.sources")
local DEFAULT_COLORS = {}
for key, value in pairs(DataSources.palette) do
	DEFAULT_COLORS[key] = value
end
local DEFAULT_GRID = DataSources.grid or {}

local function streamWithRandomDelay(records, opts)
	opts = opts or {}
	local minDelay = opts.minDelay or 0
	local maxDelay = math.max(opts.maxDelay or minDelay, minDelay)

	return Observable.create(function(observer)
		local index = 1
		local cancelled = false

		local function emitNext()
			if cancelled then
				return
			end

			local record = records[index]
			if not record then
				observer:onCompleted()
				return
			end

			observer:onNext(record)
			index = index + 1
			local nextRecord = records[index]
			if not nextRecord then
				observer:onCompleted()
				return
			end

			local delay = minDelay
			if maxDelay > minDelay then
				delay = minDelay + math.random() * (maxDelay - minDelay)
			end

			rx.scheduler.schedule(emitNext, delay)
		end

		local initialDelay = minDelay
		if maxDelay > minDelay then
			initialDelay = minDelay + math.random() * (maxDelay - minDelay)
		end
		rx.scheduler.schedule(emitNext, initialDelay)

		return function()
			cancelled = true
		end
	end)
end
PreRender.streamWithRandomDelay = streamWithRandomDelay

local function cloneColor(color)
	return { color[1], color[2], color[3], color[4] or 1 }
end

local function clampAlpha(alpha)
	if alpha == nil then
		return 0
	end
	if alpha < 0 then
		return 0
	end
	if alpha > 100 then
		return 100
	end
	return alpha
end

local PreRenderState = {}
PreRenderState.__index = PreRenderState

function PreRenderState.new(opts)
	opts = opts or {}
	local state = setmetatable({
		columns = opts.columns or 32,
		rows = opts.rows or 32,
		maxEntries = (opts.columns or 32) * (opts.rows or 32),
		palette = opts.palette or DEFAULT_COLORS,
		fadePerSecond = opts.fadePerSecond
			or (opts.fadeDuration and (100 / opts.fadeDuration))
			or (100 / DEFAULT_FADE_DURATION),
		idMapper = opts.idMapper,
		order = {},
		entries = {},
		subscriptions = {},
	}, PreRenderState)
	return state
end

function PreRenderState:decayEntry(entry, amount)
	local decay = amount or 0
	if decay <= 0 then
		return
	end
	entry.alpha = clampAlpha((entry.alpha or 100) - decay)
end

function PreRenderState:decayAll(amount)
	for _, entry in pairs(self.entries) do
		self:decayEntry(entry, amount)
	end
end

function PreRenderState:advance(dt)
	if not dt or dt <= 0 then
		return
	end
	local amount = self.fadePerSecond * dt
	if amount <= 0 then
		return
	end
	self:decayAll(amount)
end

local function mixColors(entry, templateColor)
	local existingWeight = clampAlpha(entry.alpha or 0) / 100
	local newWeight = 1 - existingWeight
	if existingWeight <= 0 then
		return cloneColor(templateColor)
	end
	return {
		entry.color[1] * existingWeight + templateColor[1] * newWeight,
		entry.color[2] * existingWeight + templateColor[2] * newWeight,
		entry.color[3] * existingWeight + templateColor[3] * newWeight,
		1,
	}
end

function PreRenderState:ingest(id, paletteKey, info)
	if not id then
		return nil
	end
	local template = self.palette[paletteKey]
	if not template then
		return nil
	end

	local entry = self.entries[id]
	if not entry then
		entry = {
			id = id,
			color = cloneColor(template),
			alpha = 100,
			meta = info,
			sources = { paletteKey },
		}
		self.entries[id] = entry
		table.insert(self.order, id)
	else
		entry.color = mixColors(entry, template)
		entry.alpha = 100
		entry.sources[#entry.sources + 1] = paletteKey
		if info ~= nil then
			entry.meta = info
		end
	end
	return entry
end

function PreRenderState:indexToCoordinate(index)
	local col = ((index - 1) % self.columns) + 1
	local row = math.floor((index - 1) / self.columns) + 1
	return col, row
end

function PreRenderState:coordinateForEntry(entry, index)
	if self.idMapper then
		local col, row = self.idMapper(entry.id, self)
		if col and row then
			return col, row
		end
	end
	return self:indexToCoordinate(index)
end

function PreRenderState:forEachInOrder(callback)
	for index, id in ipairs(self.order) do
		local entry = self.entries[id]
		if entry then
			local col, row = self:coordinateForEntry(entry, index)
			if row <= self.rows and col <= self.columns then
				local continue = callback(entry, col, row, index)
				if continue == false then
					break
				end
			end
		end
	end
end

function PreRenderState:attachSource(opts)
	assert(opts and opts.observable, "opts.observable is required")
	assert(opts.paletteKey, "opts.paletteKey is required")
	assert(type(opts.extract) == "function", "opts.extract must be a function")

	local subscription = opts.observable:subscribe(function(value)
		local id, info = opts.extract(value)
		if id then
			self:ingest(id, opts.paletteKey, info)
		end
	end)
	self.subscriptions[#self.subscriptions + 1] = subscription
	return subscription
end

function PreRenderState:teardown()
	for _, subscription in ipairs(self.subscriptions) do
		if subscription and subscription.unsubscribe then
			subscription:unsubscribe()
		end
	end
	self.subscriptions = {}
end

PreRender.State = PreRenderState
PreRender.DEFAULT_COLORS = DEFAULT_COLORS
PreRender.DEFAULT_FADE_DURATION = DEFAULT_FADE_DURATION

function PreRender.rasterIdMapper(minId, wrap)
	minId = minId or 0
	return function(id, state)
		if type(id) ~= "number" then
			return nil, nil
		end
		local offset = math.max(0, math.floor(id - minId))
		local col = (offset % state.columns) + 1
		local row = math.floor(offset / state.columns) + 1
		if wrap and row > state.rows then
			row = ((row - 1) % state.rows) + 1
		end
		return col, row
	end
end

local function makeCustomers()
	local delays = DataSources.streamDelays and DataSources.streamDelays.customers or nil
	return Schema.wrap("customers", PreRender.streamWithRandomDelay(DataSources.customers, delays), { idField = "id" })
end

local function makeOrders()
	local delays = DataSources.streamDelays and DataSources.streamDelays.orders or nil
	return Schema.wrap("orders", PreRender.streamWithRandomDelay(DataSources.orders, delays), { idField = "orderId" })
end

local function cloneOptions(opts)
	if not opts then
		return {}
	end
	local copy = {}
	for key, value in pairs(opts) do
		copy[key] = value
	end
	return copy
end

function PreRender.buildDemoStates(opts)
	opts = opts or {}
	opts.columns = opts.columns or DEFAULT_GRID.columns or 32
	opts.rows = opts.rows or DEFAULT_GRID.rows or 32
	if not opts.idMapper then
		opts.idMapper = PreRender.rasterIdMapper(DataSources.minCustomerId or 0, true)
	end
	local innerOpts = cloneOptions(opts)
	local outerOpts = cloneOptions(opts)
	local innerState = PreRenderState.new(innerOpts)
	local outerState = PreRenderState.new(outerOpts)

	local customers = makeCustomers()
	local orders = makeOrders()

	innerState:attachSource({
		observable = customers,
		paletteKey = "customers",
		extract = function(record)
			if not record then
				return nil
			end
			return record.id, { label = ("Customer %s"):format(record.name or record.id) }
		end,
	})

	innerState:decayAll(opts and opts.decayBetween or 40)

	innerState:attachSource({
		observable = orders,
		paletteKey = "orders",
		extract = function(record)
			if not record or not record.customerId then
				return nil
			end
			local label = string.format("Order %s → %s", record.orderId, record.customerId)
			return record.customerId, { label = label }
		end,
	})

	innerState:decayAll(opts and opts.decayBetween or 40)

	local join, expired = JoinObservable.createJoinObservable(customers, orders, {
		on = {
			customers = "id",
			orders = "customerId",
		},
		joinType = "left",
		expirationWindow = DataSources.expirationWindow or { mode = "count", maxItems = 5 },
	})

	outerState:attachSource({
		observable = join,
		paletteKey = "joined",
		extract = function(result)
			local customer = result:get("customers")
			local order = result:get("orders")
			local id = customer and customer.id or order and order.customerId or nil
			if not id then
				return nil
			end
			local label
			if customer and order then
				label = string.format("%s + order %s", customer.name, order.orderId)
			elseif customer then
				label = string.format("%s (no order)", customer.name)
			else
				label = string.format("order %s (no customer)", order.orderId)
			end
			return id, { label = label }
		end,
	})

	if expired then
		outerState:attachSource({
			observable = expired,
			paletteKey = "expired",
			extract = function(packet)
				if not packet then
					return nil
				end
				local schemaName = packet.schema
				local result = packet.result
				if not result then
					return nil
				end
				local record
				if schemaName then
					record = result:get(schemaName)
				end
				if not record then
					local names = result:schemaNames()
					for _, name in ipairs(names) do
						record = result:get(name)
						if record then
							break
						end
					end
				end
				if not record then
					return nil
				end
				local id
				if schemaName == "orders" and record.customerId then
					id = record.customerId
				else
					id = record.id or (record.RxMeta and record.RxMeta.id)
				end
				if not id then
					return nil
				end
				return id, {
					expired = true,
					schema = schemaName or "expired",
					record = record,
				}
			end,
		})
	end

	return innerState, outerState
end

function PreRender.buildDemoState(opts)
	local innerState = PreRender.buildDemoStates(opts)
	return innerState
end

return PreRender
