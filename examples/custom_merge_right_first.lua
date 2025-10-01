-- Expected console: MERGE lines show right records forwarded first, then join matches for ids 1 and 2.
require("bootstrap")
local io = require("io")

local rx = require("reactivex")
local JoinObservable = require("JoinObservable")

local leftStream = rx.Observable.fromTable({
	{ id = 1, side = "left", note = "would normally arrive first" },
	{ id = 2, side = "left", note = "still left" },
})

local rightStream = rx.Observable.fromTable({
	{ id = 1, side = "right", note = "right events" },
	{ id = 2, side = "right", note = "another right" },
})

local function rightFirstMerge(leftTagged, rightTagged)
	local function log(observable)
		return observable:map(function(packet)
			local entry = packet.entry or {}
			print(("[MERGE] forwarding %s id=%s"):format(packet.side, entry.id or "nil"))
			return packet
		end)
	end

	-- Concatenating streams drains right entries before left ones, forcing a right-first order.
	return rx.Observable.concat(log(rightTagged), log(leftTagged))
end

local joinStream = JoinObservable.createJoinObservable(leftStream, rightStream, {
	on = "id",
	joinType = "inner",
	merge = rightFirstMerge, -- Custom merge enforces a deterministic right-before-left ordering.
})

joinStream:subscribe(function(pair)
	print(("[JOIN] matched id=%d"):format(pair.left.id))
end, function(err)
	io.stderr:write(("Join error: %s\n"):format(err))
end, function()
	print("Join stream finished.")
end)
