local package = require("package")
package.path = "./?.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require('LQR/bootstrap')

local Schema = require("LQR/JoinObservable/schema")
local SchemaHelpers = require("tests/support/schema_helpers")
local Result = require("LQR/JoinObservable/result")

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

	it("retains id and sourceTime when schemas are renamed", function()
		local res = Result.new()
		res:attach("alpha", {
			value = 5,
			extra1 = 1,
			extra2 = 2,
			extra3 = 3,
			extra4 = 4,
			extra5 = 5,
			extra6 = 6,
			extra7 = 7,
			extra8 = 8,
			extra9 = 9,
			extra10 = 10,
			RxMeta = {
				schema = "alpha",
				id = 9,
				idField = "id",
				sourceTime = 42,
			},
		})

		local renamed = Result.selectSchemas(res, { alpha = "beta" })
		local payload = renamed:get("beta")
		assert.is_table(payload)
		assert.are.equal(9, payload.RxMeta.id)
		assert.are.equal("id", payload.RxMeta.idField)
		assert.are.equal(42, payload.RxMeta.sourceTime)
		assert.are.equal("beta", payload.RxMeta.schema)
	end)
end)
