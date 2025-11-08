local Builder = require("Query.builder")

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

return Query
