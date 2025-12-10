local package = require("package")
package.path = "./?.lua;./?/init.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require('LQR.bootstrap')

local Schema = require("JoinObservable.schema")

---@diagnostic disable: undefined-global
describe("Schema helpers", function()
	it("wraps rows into an observable with default idField", function()
		local rows = {
			{ id = 1, sourceTime = 5 },
			{ id = 2, sourceTime = 6 },
		}

		local bucket = {}
		Schema.observableFromTable("events", rows):subscribe(function(record)
			bucket[#bucket + 1] = record
		end)

		assert.are.equal(2, #bucket)
		assert.are.equal("events", bucket[1].RxMeta.schema)
		assert.are.equal(1, bucket[1].RxMeta.id)
		assert.are.equal("id", bucket[1].RxMeta.idField)
	end)

	it("accepts idField shorthand string", function()
		local rows = {
			{ uuid = "x-1", payload = true },
		}

		local bucket = {}
		Schema.observableFromTable("events", rows, "uuid"):subscribe(function(record)
			bucket[#bucket + 1] = record
		end)

		assert.are.equal(1, #bucket)
		assert.are.equal("x-1", bucket[1].RxMeta.id)
		assert.are.equal("uuid", bucket[1].RxMeta.idField)
	end)

	it("honors idSelector and sourceTimeField options", function()
		local rx = require("reactivex")
		local subject = rx.Subject.create()

		local bucket = {}
		Schema.wrap("events", subject, {
			idSelector = function(rec)
				return rec.customId
			end,
			sourceTimeField = "observedAt",
		}):subscribe(function(record)
			bucket[#bucket + 1] = record
		end)

		subject:onNext({ customId = 77, observedAt = 12345 })

		assert.are.equal(1, #bucket)
		local rec = bucket[1]
		assert.are.equal(77, rec.RxMeta.id)
		assert.are.equal("custom", rec.RxMeta.idField)
		assert.are.equal(12345, rec.RxMeta.sourceTime)
	end)
end)
