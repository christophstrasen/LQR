---@class JoinResult
---@field RxMeta table
local Result = {}
Result.__index = Result

local function cloneSchemaMeta(meta, overrideSchema)
	if type(meta) ~= "table" then
		return {}
	end

	-- Explainer: schema metadata drives downstream aliasing, so we shallow-copy it
	-- to decouple renamed aliases without rewriting the entire record.
	return {
		schema = overrideSchema or meta.schema,
		schemaVersion = meta.schemaVersion,
		sourceTime = meta.sourceTime,
		joinKey = meta.joinKey,
	}
end

local function shallowCopyRecord(record)
	if type(record) ~= "table" then
		return nil
	end

	-- Explainer: we only copy the top level so callers can mutate the forwarded
	-- record if they intentionally need to; nested tables remain shared references.
	local copy = {}
	for key, value in pairs(record) do
		if key ~= "RxMeta" then
			copy[key] = value
		end
	end
	return copy
end

function Result.new()
	return setmetatable({
		RxMeta = {
			schemas = {},
		},
	}, Result)
end

function Result:attach(alias, record)
	assert(alias and alias ~= "", "alias is required when attaching schema payloads")
	if record == nil then
		return self
	end

	self[alias] = record
	self.RxMeta.schemas[alias] = cloneSchemaMeta(record.RxMeta)
	return self
end

function Result:get(alias)
	return self[alias]
end

function Result:aliases()
	local output = {}
	for alias in pairs(self.RxMeta.schemas) do
		table.insert(output, alias)
	end
	table.sort(output)
	return output
end

---Creates a new JoinResult containing the provided alias mapping.
---@param source JoinResult
---@param aliasMap table|nil @mapping of sourceAlias -> newAlias, or array of aliases to copy verbatim
---@return JoinResult
function Result.selectAliases(source, aliasMap)
	assert(getmetatable(source) == Result, "source must be a JoinResult")

	local mapping = {}
	if not aliasMap then
		for alias in pairs(source.RxMeta.schemas) do
			mapping[alias] = alias
		end
	else
		local handled = false
		for key, value in pairs(aliasMap) do
			handled = true
			if type(key) == "number" then
				mapping[value] = value
			else
				mapping[key] = value
			end
		end
		if not handled then
			for alias in pairs(source.RxMeta.schemas) do
				mapping[alias] = alias
			end
		end
	end

	local selection = Result.new()
	for fromAlias, toAlias in pairs(mapping) do
		-- Explainer: attachFrom keeps metadata aligned with the alias so downstream
		-- joins can read `result:get(toAlias)` without worrying about its origin.
		selection:attachFrom(source, fromAlias, toAlias)
	end
	return selection
end

---Creates a full clone of the JoinResult.
---@return JoinResult
function Result:clone()
	return Result.selectAliases(self)
end

---Attaches a payload copied from another JoinResult.
---@param source JoinResult
---@param alias string
---@param newAlias string|nil
---@return JoinResult
function Result:attachFrom(source, alias, newAlias)
	assert(getmetatable(source) == Result, "source must be a JoinResult")
	assert(alias and alias ~= "", "alias is required")

	local record = source:get(alias)
	if not record then
		return self
	end

	local meta = source.RxMeta.schemas[alias]
	if not meta then
		return self
	end

	local aliasName = newAlias or alias
	local copy = shallowCopyRecord(record) or {}
	copy.RxMeta = cloneSchemaMeta(meta, aliasName)

	-- Explainer: attach() adds the renamed payload just like a native match result,
	-- ensuring observers see a consistent schema/alias map even when data is forwarded.
	return self:attach(aliasName, copy)
end

return Result
