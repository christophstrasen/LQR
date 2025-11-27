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

local function applySchemaCounts(payload, values)
	if type(values) ~= "table" then
		return
	end
	-- Root per-schema tally (_count[schema] = total)
	if type(payload._count) ~= "table" then
		payload._count = {}
	end
	for path, value in pairs(values) do
		if type(path) == "string" then
			local leafParent, leafKey = ensurePath(payload, path)
			if type(leafParent) == "table" then
				local bucket = leafParent._count
				if type(bucket) ~= "table" then
					bucket = {}
					leafParent._count = bucket
				end
				bucket[leafKey] = value
				-- Roll up per-schema totals.
				local schemaName = path:match("([^%.]+)")
				if schemaName and schemaName ~= "" then
					payload._count[schemaName] = (payload._count[schemaName] or 0) + value
				end
			end
		end
	end
end

local function applyAliases(payload, aliases)
	if type(aliases) ~= "table" then
		return
	end
	for path, value in pairs(aliases) do
		if type(path) == "string" then
			local leafParent, leafKey = ensurePath(payload, path)
			if type(leafParent) == "table" then
				-- Aliases mirror the aggregate value onto a user-visible path; clobber is allowed.
				leafParent[leafKey] = value
			end
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
	local rowCount = aggregates.rowCount or aggregates.row_count or aggregates._count or 0

	local payload = {
		_count_all = rowCount,
		_group_key = opts.key,
		window = opts.window,
	}
	payload.RxMeta = {
		schema = groupName,
		groupKey = opts.key,
		groupName = groupName,
		view = "aggregate",
		shape = "group_aggregate",
	}
	if opts.rawState ~= nil then
		payload._raw_state = opts.rawState
	end

	applyAggregateKind(payload, "sum", aggregates.sum)
	applyAggregateKind(payload, "avg", aggregates.avg)
	applyAggregateKind(payload, "min", aggregates.min)
	applyAggregateKind(payload, "max", aggregates.max)
	applyAggregateKind(payload, "count", aggregates.count)
	applySchemaCounts(payload, aggregates.count)
	applyAliases(payload, aggregates.aliases)

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
	local rowCount = aggregates.rowCount or aggregates.row_count or aggregates._count or 0
	local enriched = {}

	-- Shallow copy existing row schemas/fields.
	if type(row) == "table" then
		for k, v in pairs(row) do
			enriched[k] = v
		end
	end

	enriched._count_all = rowCount
	enriched._group_key = opts.key
	enriched.RxMeta = {
		schema = opts.groupName or (opts.key ~= nil and tostring(opts.key)) or nil,
		groupKey = opts.key,
		groupName = opts.groupName or (opts.key ~= nil and tostring(opts.key)) or nil,
		view = "enriched",
		shape = "group_enriched",
	}

	applyAggregateKind(enriched, "sum", aggregates.sum)
	applyAggregateKind(enriched, "avg", aggregates.avg)
	applyAggregateKind(enriched, "min", aggregates.min)
	applyAggregateKind(enriched, "max", aggregates.max)
	applyAggregateKind(enriched, "count", aggregates.count)
	applySchemaCounts(enriched, aggregates.count)
	applyAliases(enriched, aggregates.aliases)

	-- Expose a synthetic schema so enriched rows can be wrapped/consumed downstream.
	local syntheticName = enriched.RxMeta.groupName or "_groupBy"
	local synthetic = {
		_count_all = enriched._count_all,
		_group_key = opts.key,
		RxMeta = {
			schema = syntheticName,
			groupKey = enriched.RxMeta.groupKey,
			groupName = syntheticName,
			view = "enriched",
			shape = "group_enriched",
		},
	}
	applyAggregateKind(synthetic, "sum", aggregates.sum)
	applyAggregateKind(synthetic, "avg", aggregates.avg)
	applyAggregateKind(synthetic, "min", aggregates.min)
	applyAggregateKind(synthetic, "max", aggregates.max)
	applyAggregateKind(synthetic, "count", aggregates.count)
	applySchemaCounts(synthetic, aggregates.count)
	applyAliases(synthetic, aggregates.aliases)
	local syntheticKey = syntheticName
	if not syntheticKey:match("^_groupBy:") then
		syntheticKey = "_groupBy:" .. syntheticKey
	end
	enriched[syntheticKey] = synthetic
	-- Ensure a prefixed alias exists even if the provided groupName was already prefixed or missing.
	local aliasKey = "_groupBy:" .. (syntheticName:gsub("^_groupBy:", ""))
	if aliasKey ~= syntheticKey then
		enriched[aliasKey] = synthetic
	end

	return enriched
end

return M
