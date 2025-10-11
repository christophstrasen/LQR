require("bootstrap")

local rx = require("reactivex")
local JoinObservable = require("JoinObservable")
local Schema = require("JoinObservable.schema")
local uv = require("luv")

-- Demo: periodic GC using gcIntervalSeconds with a custom scheduler (luv timers).
local function schedulePeriodic(delaySeconds, fn)
	local timer = uv.new_timer()
	timer:start((delaySeconds or 0) * 1000, (delaySeconds or 0) * 1000, fn)
	return {
		unsubscribe = function()
			timer:stop()
			timer:close()
		end,
	}
end

local leftSubject = rx.Subject.create()
local rightSubject = rx.Subject.create()
local left = Schema.wrap("left", leftSubject, { idField = "id" })
local right = Schema.wrap("right", rightSubject, { idField = "id" })

local join, expired = JoinObservable.createJoinObservable(left, right, {
	on = "id",
	joinType = "left",
	expirationWindow = {
		mode = "interval",
		field = "ts",
		offset = 1,
		currentFn = function()
			return os.time()
		end,
	},
	gcIntervalSeconds = 1,
	gcScheduleFn = schedulePeriodic,
})

join:subscribe(function(result)
	local l = result:get("left")
	local r = result:get("right")
	print(string.format("[join] left=%s right=%s", l and l.id or "-", r and r.id or "-"))
end)

expired:subscribe(function(packet)
	print(
		string.format(
			"[expired] schema=%s key=%s reason=%s",
			packet.schema,
			tostring(packet.key),
			tostring(packet.reason)
		)
	)
end)

local function emit()
	-- Emit a stale record so the periodic GC can evict it.
	leftSubject:onNext({ id = 1, ts = os.time() - 10 })

	-- Fresh left arrives a bit later.
	local leftTimer = uv.new_timer()
	leftTimer:start(500, 0, function()
		leftSubject:onNext({ id = 2, ts = os.time() })
		leftTimer:stop()
		leftTimer:close()
	end)

	-- Matching right arrives after that.
	local rightTimer = uv.new_timer()
	rightTimer:start(1200, 0, function()
		rightSubject:onNext({ id = 2, ts = os.time() })
		rightTimer:stop()
		rightTimer:close()
	end)

	-- Finish after a bit so we can see GC and completion.
	local doneTimer = uv.new_timer()
	doneTimer:start(3000, 0, function()
		print("[example] completing subjects")
		leftSubject:onCompleted()
		rightSubject:onCompleted()
		doneTimer:stop()
		doneTimer:close()
		uv.stop()
	end)
end

emit()
uv.run()
