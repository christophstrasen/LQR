-- Helpers for tagging upstream records with RxMeta schema metadata before joining.
---@class rx.Subscription
---@field unsubscribe fun(self:rx.Subscription)

---@class rx.Observable
---@field map fun(self:rx.Observable, mapper:fun(value:any):any):rx.Observable
---@field subscribe fun(self:rx.Observable, onNext:fun(value:any), onError:fun(err:any)|nil, onCompleted:fun()|nil):rx.Subscription

local rx = require("reactivex")
local Log = require("util.log").withTag("join")
local Schema = {}
local invalidVersionNotified = {}

local function isPositiveInteger(value)
	return type(value) == "number" and value > 0 and value == math.floor(value)
end

local function assertObservable(observable)
	if type(observable) ~= "table" or type(observable.subscribe) ~= "function" then
		error("Schema.wrap expects an rx.Observable")
	end
	if type(observable.map) ~= "function" then
		error("Schema.wrap requires an observable that supports :map")
	end
end

local function assertSchemaName(schemaName)
	if type(schemaName) ~= "string" or schemaName == "" then
		error("schemaName must be a non-empty string")
	end
end

local function normalizeSchemaVersion(schemaName, schemaVersion)
	if schemaVersion == nil then
		return nil
	end
	if not isPositiveInteger(schemaVersion) then
		if not invalidVersionNotified[schemaName] then
			invalidVersionNotified[schemaName] = true
			Log:warn(
				"Ignoring invalid schemaVersion for schema '%s': expected positive integer, got %s",
				schemaName,
				tostring(schemaVersion)
			)
		end
		return nil
	end
	return schemaVersion
end

---Ensures the provided record yields a valid RxMeta table.
---@param record table
---@param context string|nil
---@return table meta
function Schema.assertRecordHasMeta(record, context)
	if type(record) ~= "table" then
		error(("Expected record table%s, got %s"):format(context and (" for " .. context) or "", type(record)))
	end

	local meta = record.RxMeta
	if type(meta) ~= "table" then
		error(
			("Record%s is missing RxMeta metadata. Wrap the source via Schema.wrap before passing it into JoinObservable."):format(
				context and (" for " .. context) or ""
			)
		)
	end

	local schemaName = meta.schema
	if type(schemaName) ~= "string" or schemaName == "" then
		error(
			("Record%s has invalid RxMeta.schema (expected non-empty string)"):format(
				context and (" for " .. context) or ""
			)
		)
	end

	meta.schemaVersion = normalizeSchemaVersion(schemaName, meta.schemaVersion)

	if meta.sourceTime ~= nil and type(meta.sourceTime) ~= "number" then
		error(
			("Record%s has invalid RxMeta.sourceTime for schema '%s' (expected number)"):format(
				context and (" for " .. context) or "",
				schemaName
			)
		)
	end

	return meta
end

---Wraps an observable to enforce/populate RxMeta.schema metadata.
---@param schemaName string
---@param observable rx.Observable
---@param opts table|nil
---@return rx.Observable
function Schema.wrap(schemaName, observable, opts)
	assertObservable(observable)
	assertSchemaName(schemaName)

	opts = opts or {}
	local desiredVersion = normalizeSchemaVersion(schemaName, opts.schemaVersion)

	local idField = opts.idField
	local idSelector = opts.idSelector
	if idField ~= nil then
		if type(idField) ~= "string" or idField == "" then
			error("opts.idField must be a non-empty string if provided")
		end
	end
	if idSelector ~= nil and type(idSelector) ~= "function" then
		error("opts.idSelector must be a function if provided")
	end
	if idField ~= nil and idSelector ~= nil then
		error("Provide only one of opts.idField or opts.idSelector")
	end
	local idLabel = idField or opts.idLabel or opts.idFieldName or "custom"

local function deriveId(record)
	if idField then
		return record[idField]
	end
	if idSelector then
		local ok, value = pcall(idSelector, record)
		if not ok then
			Log:warn(
				"Schema '%s' idSelector failed (%s); dropping record",
				schemaName,
				tostring(value)
			)
			return nil, true
		end
		return value
	end
	return record.id
end

	local function processRecord(record)
		if type(record) ~= "table" then
			error(("Schema.wrap(%s) expects table records, got %s"):format(schemaName, type(record)))
		end

		local meta = record.RxMeta
		if meta then
			Schema.assertRecordHasMeta(record, ("schema '%s'"):format(schemaName))
			if meta.schema ~= schemaName then
				error(
					("Schema.wrap expected schema '%s' but record already labeled as '%s'"):format(
						schemaName,
						tostring(meta.schema)
					)
				)
			end
			if desiredVersion ~= nil then
				if meta.schemaVersion == nil then
					meta.schemaVersion = desiredVersion
				elseif meta.schemaVersion ~= desiredVersion then
					error(
						("Schema.wrap(%s) cannot override existing schemaVersion (%s vs requested %s)"):format(
							schemaName,
							tostring(meta.schemaVersion),
							tostring(desiredVersion)
						)
					)
				end
			end
		else
			meta = {
				schema = schemaName,
				schemaVersion = desiredVersion,
			}
			record.RxMeta = meta
		end

		if meta.id == nil then
			local idValue, selectorErrored = deriveId(record)
			if idValue == nil then
				if idField or idSelector then
					local reason
					if selectorErrored then
						reason = "selector error"
					elseif idField then
						reason = ("missing field '%s'"):format(idField)
					else
						reason = "selector returned nil"
					end
					Log:warn("Dropped record for schema '%s' because id could not be resolved (%s)", schemaName, reason)
				else
					Log:warn(
						"Dropped record for schema '%s' because RxMeta.id was missing and no idField/idSelector was configured",
						schemaName
					)
				end
				return nil
			end
			meta.id = idValue
			meta.idField = idField or (idSelector and idLabel) or meta.idField or "custom"
		else
			meta.idField = meta.idField or idField or (idSelector and idLabel) or meta.idField or "unknown"
	end

	return record
end

	---@diagnostic disable-next-line
	return observable
			:map(processRecord)
			:filter(function(record)
				return record ~= nil
			end)
end

return Schema
