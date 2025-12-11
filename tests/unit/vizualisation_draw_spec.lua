local package = require("package")
package.path = "./?.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require('LQR/bootstrap')

local Draw = require("vizualisation/core/draw")
local CellLayers = require("vizualisation/core/cell_layers")

local EMPTY_CELL_COLOR = { 0.2, 0.2, 0.2, 1 }

local function colorsMatch(lhs, rhs)
	local function channel(value)
		return math.floor((value or 0) * 255 + 0.5)
	end
	return channel(lhs[1]) == channel(rhs[1])
		and channel(lhs[2]) == channel(rhs[2])
		and channel(lhs[3]) == channel(rhs[3])
		and channel(lhs[4]) == channel(rhs[4])
end

local function installLoveStub(recordedRects)
	local currentColor = { 0, 0, 0, 1 }
	_G.love = _G.love or {}
	love.timer = love.timer or { getTime = function()
		return 0
	end }
	love.graphics = {
		setColor = function(color)
			currentColor = {
				(color and color[1]) or 0,
				(color and color[2]) or 0,
				(color and color[3]) or 0,
				(color and color[4]) or 1,
			}
		end,
		setLineWidth = function() end,
		rectangle = function(mode, x, y, w, h)
			recordedRects[#recordedRects + 1] = {
				mode = mode,
				x = x,
				y = y,
				w = w,
				h = h,
				color = {
					currentColor[1],
					currentColor[2],
					currentColor[3],
					currentColor[4],
				},
			}
		end,
		push = function() end,
		pop = function() end,
		printf = function() end,
	}
end

local function buildSnapshot(columns, rows)
	local window = { columns = columns, rows = rows or 1, startId = 0 }
	local composite = CellLayers.CompositeCell.new({ maxLayers = 2 })
	local cells = { [1] = { [1] = { composite = composite } } }
	local header = { joins = { {}, {} }, window = window }
	return {
		window = window,
		cells = cells,
		meta = {
			renderTime = 0,
			maxLayers = 2,
			header = header,
		},
	}
end

---@diagnostic disable: undefined-global
describe("vizualisation draw", function()
	it("derives cell size from fixed layers in 10x10 and 100x100 modes", function()
		local smallSnapshot = buildSnapshot(10, 1)
		local smallMetrics = Draw.metrics(smallSnapshot)
		local expectedSmallContent = smallMetrics.innerSize + (smallMetrics.layersBudget * 2 * smallMetrics.layerThickness)
		assert.are.equal(expectedSmallContent, smallMetrics.contentSize)
		local expectedSmallCell = smallMetrics.contentSize + (smallMetrics.padding * 2) + (smallMetrics.outerInset * 2)
		assert.are.equal(expectedSmallCell, smallMetrics.cellSize)

		local largeSnapshot = buildSnapshot(100, 1)
		local largeMetrics = Draw.metrics(largeSnapshot)
		local expectedLargeContent = largeMetrics.innerSize + (largeMetrics.layersBudget * 2 * largeMetrics.layerThickness)
		assert.are.equal(expectedLargeContent, largeMetrics.contentSize)
		local expectedLargeCell = largeMetrics.contentSize + (largeMetrics.padding * 2) + (largeMetrics.outerInset * 2)
		assert.are.equal(expectedLargeCell, largeMetrics.cellSize)
	end)

	it("keeps inner fill thickness constant regardless of join count in 10x10 mode", function()
		local recordedRects = {}
		installLoveStub(recordedRects)
		local snapshot = buildSnapshot(10, 1)
		local metrics = Draw.metrics(snapshot)
		Draw.drawSnapshot(snapshot, {})
		local innerRects = {}
		for _, rect in ipairs(recordedRects) do
			if rect.mode == "fill" and colorsMatch(rect.color, EMPTY_CELL_COLOR) then
				table.insert(innerRects, rect)
			end
		end
		assert.is_true(#innerRects > 0)
		assert.are.equal(metrics.innerSize, innerRects[1].w)
	end)

	it("keeps inner fill thickness constant in 100x100 mode", function()
		local recordedRects = {}
		installLoveStub(recordedRects)
		local snapshot = buildSnapshot(100, 1)
		local metrics = Draw.metrics(snapshot)
		Draw.drawSnapshot(snapshot, {})
		local innerRects = {}
		for _, rect in ipairs(recordedRects) do
			if rect.mode == "fill" and colorsMatch(rect.color, EMPTY_CELL_COLOR) then
				table.insert(innerRects, rect)
			end
		end
		assert.is_true(#innerRects > 0)
		assert.are.equal(metrics.innerSize, innerRects[1].w)
	end)
end)
