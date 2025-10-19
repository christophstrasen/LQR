local package = require("package")
package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require("bootstrap")

local Runtime = require("viz_high_level.core.runtime")
local Renderer = require("viz_high_level.core.headless_renderer")

---@diagnostic disable: undefined-global
describe("viz_high_level headless renderer", function()
	it("maps inner and layered borders to grid cells", function()
		local palette = {
			customers = { 0.1, 0.2, 0.3, 1 },
			joined = { 0, 1, 0, 1 },
			expired = { 1, 0, 0, 1 },
		}
		local SchemaHelpers = require("tests.support.schema_helpers")
		local Query = require("Query")
		local QueryVizAdapter = require("viz_high_level.core.query_adapter")

		-- Build a small query to drive projection enrichment.
		local customersSubject, customers = SchemaHelpers.subjectWithSchema("customers", { idField = "id" })
		local adapter = QueryVizAdapter.attach(
			Query.from(customers, "customers")
				:leftJoin(customers, "customers") -- self-join to reuse schema in projection map
				:onSchemas({ customers = "id" })
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
			mixDecayHalfLife = 0.5,
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
		assert.is_not_nil(cell.inner)
		-- Color should be a mix (both red and blue components present).
		assert.is_true(cell.inner.color[1] > 0 and cell.inner.color[3] > 0)
		local initialIntensity = cell.inner.intensity or 1
		assert.is_true(initialIntensity <= 1 and initialIntensity > 0)

		-- After a gap, the cell fades before new data arrives.
		local fadedSnap = Renderer.render(runtime, palette, 5)
		local fadedCell = cellForId(fadedSnap, 10)
		assert.is_not_nil(fadedCell)
		assert.is_true((fadedCell.inner.intensity or 0) < initialIntensity)

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
		assert.is_not_nil(cell2)
		assert.is_true(cell2.inner.color[3] > cell2.inner.color[1])
		assert.is_true((cell2.inner.intensity or 0) >= (fadedCell.inner.intensity or 0))
	end)
end)
