-- Wrapper for joined rows that tracks schema metadata alongside payloads.
---@class JoinResult
---@field RxMeta table
local Result = {}
Result.__index = Result

local function cloneSchemaMeta(meta, overrideSchema)
	if type(meta) ~= "table" then
		return { schema = overrideSchema }
	end

	-- Explainer: schema metadata drives downstream schema tracking, so we shallow-copy it
	-- to decouple renamed schema names without rewriting the entire record.
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
Result.shallowCopyRecord = function(record, targetSchema)
	local copy = shallowCopyRecord(record)
	if not copy then
		return copy
	end
	copy.RxMeta = cloneSchemaMeta(record.RxMeta, targetSchema)
	return copy
end

function Result.new()
	return setmetatable({
		RxMeta = {
			schemaMap = {},
		},
	}, Result)
end

function Result:attach(schemaName, record)
	assert(schemaName and schemaName ~= "", "schemaName is required when attaching payloads")
	if record == nil then
		return self
	end

	self[schemaName] = record
	self.RxMeta.schemaMap[schemaName] = cloneSchemaMeta(record.RxMeta)
	return self
end

function Result:get(schemaName)
	return self[schemaName]
end

function Result:schemaNames()
	local output = {}
	for schema in pairs(self.RxMeta.schemaMap) do
		table.insert(output, schema)
	end
	table.sort(output)
	return output
end

---Creates a new JoinResult containing the provided schema mapping.
---@param source JoinResult
---@param schemaMap table|nil @mapping of sourceSchema -> newSchema, or array of schema names to copy verbatim
---@return JoinResult
function Result.selectSchemas(source, schemaMap)
	assert(getmetatable(source) == Result, "source must be a JoinResult")

	local mappingEntries = {}
	if not schemaMap then
		for schema in pairs(source.RxMeta.schemaMap) do
			table.insert(mappingEntries, { from = schema, to = schema })
		end
	else
		local handled = false
		-- Preserve order for array-style schema lists.
		for _, value in ipairs(schemaMap) do
			handled = true
			table.insert(mappingEntries, { from = value, to = value })
		end
		-- Also honor map-style entries.
		for key, value in pairs(schemaMap) do
			if type(key) ~= "number" then
				handled = true
				table.insert(mappingEntries, { from = key, to = value })
			end
		end
		if not handled then
			for schema in pairs(source.RxMeta.schemaMap) do
				table.insert(mappingEntries, { from = schema, to = schema })
			end
		end
	end

	local selection = Result.new()
	for _, entry in ipairs(mappingEntries) do
		-- Explainer: attachFrom keeps metadata aligned with the schema so downstream
		-- joins can read `result:get(schemaName)` without worrying about its origin.
		selection:attachFrom(source, entry.from, entry.to)
	end
	return selection
end

---Creates a full clone of the JoinResult.
---@return JoinResult
function Result:clone()
	return Result.selectSchemas(self)
end

---Attaches a payload copied from another JoinResult.
---@param source JoinResult
---@param schemaName string
---@param newSchemaName string|nil
---@return JoinResult
function Result:attachFrom(source, schemaName, newSchemaName)
	assert(getmetatable(source) == Result, "source must be a JoinResult")
	assert(schemaName and schemaName ~= "", "schemaName is required")

	local record = source:get(schemaName)
	if not record then
		return self
	end

	local meta = source.RxMeta.schemaMap[schemaName]
	if not meta then
		return self
	end

	local targetSchemaName = newSchemaName or schemaName
	local copy = Result.shallowCopyRecord(record, targetSchemaName) or {}

	-- Explainer: attach() adds the renamed payload just like a native match result,
	-- ensuring observers see a consistent schema map even when data is forwarded.
	return self:attach(targetSchemaName, copy)
end

return Result
