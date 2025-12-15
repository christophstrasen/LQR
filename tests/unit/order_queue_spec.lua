package.path = table.concat({ package.path, "./?.lua", "./?/init.lua" }, ";")
local OrderQueue = require("LQR/util/order_queue")

describe("order_queue", function()
	it("pushes and pops in FIFO order", function()
		local q = OrderQueue.new()
		OrderQueue.push(q, "a", { id = 1 })
		OrderQueue.push(q, "b", { id = 2 })
		OrderQueue.push(q, "c", { id = 3 })

		assert.is.equal(3, q.count)
		assert.is.equal("a", (OrderQueue.pop(q) or {}).key)
		assert.is.equal("b", (OrderQueue.pop(q) or {}).key)
		assert.is.equal("c", (OrderQueue.pop(q) or {}).key)
		assert.is.equal(0, q.count)
		assert.is_nil(OrderQueue.pop(q))
	end)

	it("skips holes created by removeRecord", function()
		local q = OrderQueue.new()
		local r1, r2, r3 = {}, {}, {}
		OrderQueue.push(q, "a", r1)
		OrderQueue.push(q, "b", r2)
		OrderQueue.push(q, "c", r3)

		assert.is_true(OrderQueue.removeRecord(q, r1))
		assert.is.equal(2, q.count)

		local first = OrderQueue.pop(q)
		assert.is.equal("b", first and first.key)
		local second = OrderQueue.pop(q)
		assert.is.equal("c", second and second.key)
		assert.is.equal(0, q.count)
	end)
end)

