local package = require("package")
package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require('LQR.bootstrap')

local Runtime = require("vizualisation.core.runtime")
local Renderer = require("vizualisation.core.headless_renderer")

---@diagnostic disable: undefined-global
describe("vizualisation headless renderer", function()
	it("maps inner and layered borders to grid cells", function()
		local palette = {
			customers = { 0.1, 0.2, 0.3, 1 },
			joined = { 0, 1, 0, 1 },
			expired = { 1, 0, 0, 1 },
		}
		local SchemaHelpers = require("tests.support.schema_helpers")
		local Query = require("Query")
		local QueryVizAdapter = require("vizualisation.core.query_adapter")

		-- Build a small query to drive projection enrichment.
		local customersSubject, customers = SchemaHelpers.subjectWithSchema("customers", { idField = "id" })
		local adapter = QueryVizAdapter.attach(
			Query.from(customers, "customers")
				:leftJoin(customers, "customers") -- self-join to reuse schema in projection map
				:using({ customers = { field = "id" } })
		)

		local runtime = Runtime.new({
			maxLayers = 5,
			maxColumns = 5,
			maxRows = 2,
			startId = 10,
			adjustInterval = 0,
			header = adapter.header,
		})

		adapter.normalized:subscribe(function(evt)
			runtime:ingest(evt, 0)
		end)
		adapter.query:subscribe(function() end)

		customersSubject:onNext({ id = 10 })
		customersSubject:onCompleted()

		local snap = Renderer.render(runtime, palette, 0.1)
		assert.is_true(snap.window.startId <= 10)
		assert.is_true(snap.window.endId >= 10)
		assert.are.same(5, snap.meta.maxLayers)
		assert.is_true((snap.meta.sourceCounts.customers or 0) >= 1)
		assert.is_true((snap.meta.projectableSourceCounts.customers or 0) >= 1)
		assert.is_table(snap.meta.header.joins or {})
		assert.is_table(snap.meta.header.projection)
		assert.is_table(snap.meta.legend or {})
		assert.is_table(snap.meta.outerLegend or {})
	end)

	it("blends colors for overlapping sources using decay", function()
		local runtime = Runtime.new({
			maxLayers = 3,
			maxColumns = 10,
			maxRows = 1,
			startId = 10,
			visualsTTL = 0.5,
			header = {
				projection = { domain = "customers" },
			},
		})

		local palette = {
			customers = { 1, 0, 0, 1 },
			orders = { 0, 0, 1, 1 },
			joined = { 0, 1, 0, 1 },
			expired = { 1, 1, 0, 1 },
		}

		runtime:ingest({
			type = "source",
			schema = "customers",
			id = 10,
			projectionKey = 10,
			projectable = true,
		}, 0)
		-- Overlapping event shortly after with different schema mixes colors.
		runtime:ingest({
			type = "source",
			schema = "orders",
			id = 10,
			projectionKey = 10,
			projectable = true,
		}, 0.1)

		local function cellForId(snapshot, id)
			local window = snapshot.window
			local idx = id - window.startId + 1
			local col = ((idx - 1) % window.columns) + 1
			local row = math.floor((idx - 1) / window.columns) + 1
			return snapshot.cells[col] and snapshot.cells[col][row]
		end

		local snap = Renderer.render(runtime, palette)
		local cell = cellForId(snap, 10)
		assert.is_not_nil(cell)
		local innerRegion = cell.composite and cell.composite:getInner()
		assert.is_not_nil(innerRegion)
		local initialColor = select(1, innerRegion:getColor())
		assert.is_not_nil(initialColor)
		assert.is_true(initialColor[1] > 0 and initialColor[3] > 0)

		-- After a gap, the cell fades before new data arrives.
		local fadedSnap = Renderer.render(runtime, palette, 5)
		local fadedCell = cellForId(fadedSnap, 10)
		local fadedRegion = fadedCell.composite and fadedCell.composite:getInner()
		assert.is_not_nil(fadedRegion)
		local fadedColor = select(1, fadedRegion:getColor())
		assert.is_not_nil(fadedColor)
		local backgroundBlue = 0.2
		local distInitial = math.abs(initialColor[3] - backgroundBlue)
		local distFaded = math.abs(fadedColor[3] - backgroundBlue)
		assert.is_true(distFaded < distInitial)

		-- New schema takes over at the same timestamp, restoring intensity.
		runtime:ingest({
			type = "source",
			schema = "orders",
			id = 10,
			projectionKey = 10,
			projectable = true,
		}, 5)

		local snap2 = Renderer.render(runtime, palette, 5)
		local cell2 = cellForId(snap2, 10)
		local finalRegion = cell2.composite and cell2.composite:getInner()
		assert.is_not_nil(finalRegion)
		local finalColor = select(1, finalRegion:getColor())
		assert.is_not_nil(finalColor)
		assert.is_true(finalColor[3] > finalColor[1])
		assert.is_true(finalColor[3] > fadedColor[3])
	end)

	it("counts matches per layer and uses provided layer colors", function()
		local runtime = Runtime.new({
			maxLayers = 3,
			maxColumns = 2,
			maxRows = 1,
			startId = 0,
			visualsTTL = 1,
			header = {
				joinColors = {
					[1] = { 1, 0, 0, 1 },
					[2] = { 0, 1, 0, 1 },
					[3] = { 0, 0, 1, 1 },
				},
			},
		})

		runtime:ingest({
			type = "match",
			layer = 2,
			projectionKey = 0,
			projectable = true,
		}, 0)
		runtime:ingest({
			type = "match",
			layer = 3,
			projectionKey = 1,
			projectable = true,
		}, 0)

		local snap = Renderer.render(runtime, {}, 0)
		assert.is_table(snap.meta.outerLegend)
		assert.are.equal(5, #snap.meta.outerLegend) -- three layers + expire + group-expire
		-- Legend is ordered from inner (highest layer) to outer (layer 1 is final).
		local finalEntry = snap.meta.outerLegend[3]
		assert.is_true(tostring(finalEntry.label):match("^Final %(Layer 1") ~= nil)
		local layer3 = snap.meta.outerLegend[1]
		assert.are.same({ 0, 0, 1, 1 }, layer3.color)
		assert.are.equal(1, layer3.total)
		local layer2 = snap.meta.outerLegend[2]
		assert.are.same({ 0, 1, 0, 1 }, layer2.color)
		assert.are.equal(1, layer2.total)
	end)

	it("tracks expire counts by reason", function()
		local runtime = Runtime.new({
			maxLayers = 1,
			maxColumns = 2,
			maxRows = 2,
			startId = 0,
			visualsTTL = 1,
		})

		runtime:ingest({
			type = "expire",
			schema = "orders",
			id = 0,
			projectionKey = 0,
			projectable = true,
			layer = 1,
			reason = "timeout",
		}, 0)
		runtime:ingest({
			type = "expire",
			schema = "orders",
			id = 1,
			projectionKey = 1,
			projectable = false,
			layer = 1,
			reason = "evict",
		}, 0)

		local snap = Renderer.render(runtime, {}, 0)
		local expireEntry
		for _, entry in ipairs(snap.meta.outerLegend) do
			if entry.kind == "expire" then
				expireEntry = entry
				break
			end
		end
		assert.are.equal("expire", expireEntry.kind)
		assert.are.equal(2, expireEntry.total)
		assert.are.equal(1, expireEntry.projectable)
		assert.is_table(expireEntry.reasons)
		assert.are.equal(2, #expireEntry.reasons)

		local first = expireEntry.reasons[1]
		assert.are.equal("evict", first.reason)
		assert.are.equal(1, first.total)

		local second = expireEntry.reasons[2]
		assert.are.equal("timeout", second.reason)
		assert.are.equal(1, second.total)
	end)
end)
