local DataModel = require("LQR.GroupByObservable.data_model")
local Core = require("LQR.GroupByObservable.core")

local GroupByObservable = {
	dataModel = DataModel,
	createGroupByObservable = Core.createGroupByObservable,
}

return GroupByObservable
