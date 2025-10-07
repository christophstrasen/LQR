local package = require("package")
package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require("bootstrap")

local PreRender = require("viz.pre_render")
local Delay = require("viz.observable_delay")
local rx = require("reactivex")
local ScenarioLoader = require("viz.scenario_loader")
local Observables = require("viz.observables")
local Sources = ScenarioLoader.getRecipe(Observables)

local windowConfig = Sources.window
local layersConfig = windowConfig.layers or {}

local function closeEnough(a, b, eps)
	eps = eps or 1e-6
	return math.abs(a - b) <= eps
end

local originalWindowSnapshot

before_each(function()
	originalWindowSnapshot = {
		gridStartOffset = windowConfig.grid and windowConfig.grid.startOffset or nil,
		innerStartOffset = layersConfig.inner and layersConfig.inner.startOffset or nil,
		outerStartOffset = layersConfig.outer and layersConfig.outer.startOffset or nil,
		innerStreams = layersConfig.inner and layersConfig.inner.streams or nil,
		outerStreams = layersConfig.outer and layersConfig.outer.streams or nil,
	}
	rx.scheduler.reset()
end)

after_each(function()
	if windowConfig.grid then
		windowConfig.grid.startOffset = originalWindowSnapshot.gridStartOffset
	end
	if layersConfig.inner then
		layersConfig.inner.startOffset = originalWindowSnapshot.innerStartOffset
		layersConfig.inner.streams = originalWindowSnapshot.innerStreams
	end
	if layersConfig.outer then
		layersConfig.outer.startOffset = originalWindowSnapshot.outerStartOffset
		layersConfig.outer.streams = originalWindowSnapshot.outerStreams
	end
	rx.scheduler.reset()
end)

describe("PreRender State color mixing", function()
	it("blends existing color according to remaining alpha weight", function()
		local palette = {
			foo = { 0.6, 0.2, 0.1, 1 },
			bar = { 0.0, 1.0, 0.0, 1 },
		}
		local state = PreRender.State.new({
			columns = 1,
			rows = 1,
			palette = palette,
		})

		state:ingest(101, "foo")
		local entry = state.entries[101]
		entry.color = { 0.5, 0.3, 0.1, 1 }
		entry.alpha = 10 -- simulate heavy fading but not zero

		state:ingest(101, "bar")
		local mixed = state.entries[101].color

		-- existing weight should be 0.1 (alpha / 100)
		assert.is_true(closeEnough(mixed[1], 0.5 * 0.1 + 0.0 * 0.9))
		assert.is_true(closeEnough(mixed[2], 0.3 * 0.1 + 1.0 * 0.9))
		assert.is_true(closeEnough(mixed[3], 0.1 * 0.1 + 0.0 * 0.9))
	end)

	it("lets the new color dominate when the entry alpha reached zero", function()
		local palette = {
			foo = { 1.0, 0.0, 0.0, 1 },
			bar = { 0.0, 1.0, 0.0, 1 },
		}
		local state = PreRender.State.new({
			columns = 1,
			rows = 1,
			palette = palette,
		})

		state:ingest(202, "foo")
		local entry = state.entries[202]
		entry.color = { 0.2, 0.2, 0.2, 1 }
		entry.alpha = 0

		state:ingest(202, "bar")
		local color = state.entries[202].color

		assert.is_true(closeEnough(color[1], palette.bar[1]))
		assert.is_true(closeEnough(color[2], palette.bar[2]))
		assert.is_true(closeEnough(color[3], palette.bar[3]))
	end)
end)

describe("Observable delay helper", function()
	it("spaces emissions by at least the configured delay", function()
		local base = rx.Observable.fromTable({ "first", "second" })
		local delayed = Delay.withDelay(base, { minDelay = 0.5, maxDelay = 0.5 })
		local emissions = {}

		delayed:subscribe(function(value)
			emissions[#emissions + 1] = { value = value, time = rx.scheduler.get().currentTime }
		end)

		for _ = 1, 10 do
			rx.scheduler.update(0.25)
		end

		assert.are.equal(2, #emissions)
		assert.is_true(closeEnough(0.5, emissions[1].time, 1e-3))
		assert.is_true(closeEnough(1.0, emissions[2].time, 1e-3))
	end)
end)

describe("Grid start offsets", function()
	local function buildEmptyStates()
		return PreRender.buildConfiguredStates({
			columns = 4,
			rows = 4,
			fadeDuration = 5,
		})
	end

	it("applies the global grid start offset when layers do not override it", function()
		windowConfig.grid = windowConfig.grid or {}
		windowConfig.grid.startOffset = 90
		if layersConfig.inner then
			layersConfig.inner.startOffset = nil
			layersConfig.inner.streams = {}
		end
		if layersConfig.outer then
			layersConfig.outer.startOffset = nil
			layersConfig.outer.streams = {}
		end

		local states = buildEmptyStates()
		local innerState = assert(states.inner, "inner layer missing")

		local entryA = innerState:ingest(90, "customers")
		local colA, rowA = innerState:coordinateForEntry(entryA, #innerState.order)
		assert.are.same({ 1, 1 }, { colA, rowA })

		local entryB = innerState:ingest(94, "customers")
		local colB, rowB = innerState:coordinateForEntry(entryB, #innerState.order)
		assert.are.same({ 1, 2 }, { colB, rowB })

		local entryC = innerState:ingest(93, "customers")
		local colC, rowC = innerState:coordinateForEntry(entryC, #innerState.order)
		assert.are.same({ 4, 1 }, { colC, rowC })
	end)

	it("prefers per-layer start offsets over the global configuration", function()
		windowConfig.grid = windowConfig.grid or {}
		windowConfig.grid.startOffset = 0
		if layersConfig.inner then
			layersConfig.inner.startOffset = 10
			layersConfig.inner.streams = {}
		end
		if layersConfig.outer then
			layersConfig.outer.startOffset = nil
			layersConfig.outer.streams = {}
		end

		local states = buildEmptyStates()
		local innerState = assert(states.inner, "inner layer missing")
		local outerState = assert(states.outer, "outer layer missing")

		local innerEntry = innerState:ingest(10, "customers")
		local innerCol, innerRow = innerState:coordinateForEntry(innerEntry, #innerState.order)
		assert.are.same({ 1, 1 }, { innerCol, innerRow })

		local innerNext = innerState:ingest(15, "customers")
		local innerCol2, innerRow2 = innerState:coordinateForEntry(innerNext, #innerState.order)
		assert.are.same({ 2, 2 }, { innerCol2, innerRow2 })

		local outerEntry = outerState:ingest(0, "customers")
		local outerCol, outerRow = outerState:coordinateForEntry(outerEntry, #outerState.order)
		assert.are.same({ 1, 1 }, { outerCol, outerRow })

		local outerNext = outerState:ingest(1, "customers")
		local outerCol2, outerRow2 = outerState:coordinateForEntry(outerNext, #outerState.order)
		assert.are.same({ 2, 1 }, { outerCol2, outerRow2 })
	end)
end)
