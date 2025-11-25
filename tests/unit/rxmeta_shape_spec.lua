local package = require("package")
package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require("bootstrap")

local Schema = require("JoinObservable.schema")
local SchemaHelpers = require("tests.support.schema_helpers")
local Result = require("JoinObservable.result")

---@diagnostic disable: undefined-global
describe("RxMeta shapes", function()
	it("adds shape=record for wrapped sources", function()
		local subject, observable = SchemaHelpers.subjectWithSchema("customers", { idField = "id" })
		local records = {}
		observable:subscribe(function(rec)
			records[#records + 1] = rec
		end)

		subject:onNext({ id = 1 })
		assert.are.equal("record", records[1].RxMeta.shape)
	end)

	it("sets shape=join_result on JoinResult containers", function()
		local res = Result.new()
		assert.are.equal("join_result", res.RxMeta.shape)
	end)
end)
