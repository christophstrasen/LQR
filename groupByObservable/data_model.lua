local M = {}

---Splits a dotted path into segments.
---@param path string
---@return string[]
local function splitPath(path)
	local segments = {}
	for segment in string.gmatch(path or "", "[^%.]+") do
		segments[#segments + 1] = segment
	end
	return segments
end

---Ensures nested tables for a dotted path and returns the leaf table and final key.
---@param root table
---@param path string
---@return table leaf
---@return string leafKey
local function ensurePath(root, path)
	local segments = splitPath(path)
	local current = root
	for i = 1, #segments - 1 do
		local part = segments[i]
		if type(part) == "string" and part ~= "" then
			local nextNode = current[part]
			if type(nextNode) ~= "table" then
				nextNode = {}
				current[part] = nextNode
			end
			current = nextNode
		end
	end
	return current, segments[#segments]
end

---Internal helper to apply aggregate values into a payload using _sum/_avg/_min/_max prefixes.
---@param payload table
---@param aggregateKind string
---@param values table<string, number|nil>
local function applyAggregateKind(payload, aggregateKind, values)
	if type(values) ~= "table" then
		return
	end
	local prefix = "_" .. aggregateKind
	for path, value in pairs(values) do
		if type(path) == "string" then
			local leafParent, leafKey = ensurePath(payload, path)
			local bucket = leafParent[prefix]
			if type(bucket) ~= "table" then
				bucket = {}
				leafParent[prefix] = bucket
			end
			bucket[leafKey] = value
		end
	end
end

---Builds the aggregate row payload (returned via result:get(groupName) in aggregate view).
---@param opts table
---@field opts.groupName string|nil
---@field opts.key any
---@field opts.aggregates table|nil -- { count:number, sum=table, avg=table, min=table, max=table }
---@field opts.window table|nil
---@field opts.rawState table|nil
---@return table
function M.buildAggregateRow(opts)
	opts = opts or {}
	local groupName = opts.groupName or (opts.key ~= nil and tostring(opts.key)) or nil
	local aggregates = opts.aggregates or {}

	local payload = {
		key = opts.key,
		groupName = groupName,
		_count = aggregates.count or aggregates._count or 0,
		window = opts.window,
	}
	if groupName then
		payload.RxMeta = { schema = groupName }
	end
	if opts.rawState ~= nil then
		payload._raw_state = opts.rawState
	end

	applyAggregateKind(payload, "sum", aggregates.sum)
	applyAggregateKind(payload, "avg", aggregates.avg)
	applyAggregateKind(payload, "min", aggregates.min)
	applyAggregateKind(payload, "max", aggregates.max)

	return payload
end

---Builds an enriched row view (original schemas plus inline aggregates).
---@param row table
---@param opts table
---@field opts.groupName string|nil
---@field opts.key any
---@field opts.aggregates table|nil -- { count:number, sum=table, avg=table, min=table, max=table }
---@return table
function M.buildEnrichedRow(row, opts)
	opts = opts or {}
	local aggregates = opts.aggregates or {}
	local enriched = {}

	-- Shallow copy existing row schemas/fields.
	if type(row) == "table" then
		for k, v in pairs(row) do
			enriched[k] = v
		end
	end

	enriched._groupKey = opts.key
	enriched._groupName = opts.groupName or (opts.key ~= nil and tostring(opts.key)) or nil
	enriched._count = aggregates.count or aggregates._count or 0

	applyAggregateKind(enriched, "sum", aggregates.sum)
	applyAggregateKind(enriched, "avg", aggregates.avg)
	applyAggregateKind(enriched, "min", aggregates.min)
	applyAggregateKind(enriched, "max", aggregates.max)

	-- Optionally expose a synthetic schema so enriched rows can be wrapped/consumed downstream.
	if enriched._groupName then
		local synthetic = {
			_groupKey = enriched._groupKey,
			_groupName = enriched._groupName,
			_count = enriched._count,
		}
		applyAggregateKind(synthetic, "sum", aggregates.sum)
		applyAggregateKind(synthetic, "avg", aggregates.avg)
		applyAggregateKind(synthetic, "min", aggregates.min)
		applyAggregateKind(synthetic, "max", aggregates.max)
		local syntheticKey = enriched._groupName
		if not syntheticKey:match("^_groupBy:") then
			syntheticKey = "_groupBy:" .. syntheticKey
		end
		enriched[syntheticKey] = synthetic
	end

	return enriched
end

return M
