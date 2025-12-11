-- LQR entrypoint: loads bootstrap and re-exports public modules.
local Bootstrap = require("LQR/bootstrap")

local Schema = require("LQR/JoinObservable/schema")

return {
	Bootstrap = Bootstrap,
	Query = require("LQR/Query"),
	Schema = Schema,
	JoinObservable = require("LQR/JoinObservable"),
	rx = require("reactivex"),
	observableFromTable = Schema.observableFromTable,
	---Safe dot-path getter for nested tables.
	---@param tbl table|nil
	---@param path string
	---@return any
	get = function(tbl, path)
		local current = tbl
		for segment in tostring(path):gmatch("[^%.]+") do
			if type(current) ~= "table" then
				return nil
			end
			current = current[segment]
		end
		return current
	end,
}
