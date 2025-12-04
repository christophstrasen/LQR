local DataModel = require("GroupByObservable.data_model")
local Core = require("GroupByObservable.core")

local GroupByObservable = {
	dataModel = DataModel,
	createGroupByObservable = Core.createGroupByObservable,
}

return GroupByObservable
