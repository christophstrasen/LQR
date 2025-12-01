local SchemaHelpers = {}

local rx = require('reactivex')
local Observable = rx.Observable or rx
local Schema = require('JoinObservable.schema')

---Ensures the options table carries at least an idField when no selector exists.
---@param opts table|nil
---@return table
function SchemaHelpers.ensureIdOptions(opts)
	if opts == nil then
		return { idField = 'id' }
	end
	if opts.idField or opts.idSelector then
		return opts
	end
	local copy = {}
	for key, value in pairs(opts) do
		copy[key] = value
	end
	copy.idField = 'id'
	return copy
end

---Wraps a table of rows into an observable with schema metadata.
---@param schemaName string
---@param rows table
---@param opts table|nil
---@return rx.Observable
function SchemaHelpers.observableFromTable(schemaName, rows, opts)
	local options = SchemaHelpers.ensureIdOptions(opts)
	return Schema.wrap(schemaName, Observable.fromTable(rows, ipairs, true), options)
end

---Returns a subject + wrapped observable pair for the provided schema.
---@param schemaName string
---@param opts table|nil
---@return rx.Subject, rx.Observable
function SchemaHelpers.subjectWithSchema(schemaName, opts)
	local source = rx.Subject.create()
	local options = SchemaHelpers.ensureIdOptions(opts)
	return source, Schema.wrap(schemaName, source, options)
end

return SchemaHelpers
