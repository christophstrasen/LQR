local DataModel = require("groupByObservable.data_model")
local Core = require("groupByObservable.core")

local GroupByObservable = {
	dataModel = DataModel,
	createGroupByObservable = Core.createGroupByObservable,
}

return GroupByObservable
