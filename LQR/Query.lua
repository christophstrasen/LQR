require("LQR/bootstrap")

local Builder = require("LQR/Query/builder")

local Query = {}
Query.QueryBuilder = Builder.QueryBuilder

---Creates a new QueryBuilder anchored to the provided observable.
---@param source rx.Observable
---@param opts table|string|nil @optional schema label for describe/coverage checks
---@return QueryBuilder
function Query.from(source, opts)
	return Builder.newBuilder(source, opts)
end

---Alias for selection-only flows to emphasize non-join usage.
function Query.selectFrom(source, opts)
	return Query.from(source, opts)
end

---Overrides the default scheduler used for join window GC scheduling.
---@param scheduler any
function Query.setScheduler(scheduler)
	Builder.setScheduler(scheduler)
end

---Overrides the default join window used when a join step does not declare one.
---@param joinWindow table|nil
function Query.setDefaultJoinWindow(joinWindow)
	Builder.setDefaultJoinWindow(joinWindow)
end

---Overrides the default currentFn used for time/interval windows (joinWindow/groupWindow/distinct).
---@param fn fun():number|nil
function Query.setDefaultCurrentFn(fn)
	Builder.setDefaultCurrentFn(fn)
end

---Returns the effective default currentFn used for time/interval windows.
---@return fun():number
function Query.getDefaultCurrentFn()
	return Builder.getDefaultCurrentFn()
end

return Query
