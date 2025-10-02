-- Expected console: a couple of join lines plus a METRICS summary counting evictions by side/reason.
require("bootstrap")
local io = require("io")

local rx = require("reactivex")
local JoinObservable = require("JoinObservable")

local leftStream = rx.Observable.fromTable({
	{ id = 1, payload = "left-1" },
	{ id = 2, payload = "left-2" },
	{ id = 3, payload = "left-3" },
}, ipairs)

local rightStream = rx.Observable.fromTable({
	{ id = 1, payload = "right-1" },
	{ id = 2, payload = "right-2" },
	{ id = 4, payload = "right-4" },
}, ipairs)

local joinStream, expiredStream = JoinObservable.createJoinObservable(leftStream, rightStream, {
	on = "id",
	joinType = "outer",
	expirationWindow = {
		mode = "count",
		maxItems = 1, -- Keep only the most recent record per side to force quick evictions.
	},
})

local metrics = {
	total = 0,
	left = 0,
	right = 0,
	reasons = {},
}

expiredStream:subscribe(function(record)
	metrics.total = metrics.total + 1
	metrics[record.side] = metrics[record.side] + 1
	metrics.reasons[record.reason] = (metrics.reasons[record.reason] or 0) + 1
	print(
		("[EXPIRED] side=%s id=%s reason=%s"):format(
			record.side,
			record.entry and record.entry.id or "nil",
			record.reason
		)
	)
end, function(err)
	io.stderr:write(("Expired stream error: %s\n"):format(err))
end, function()
	print(
		("[METRICS] Expired total=%d left=%d right=%d reasons=%s"):format(
			metrics.total,
			metrics.left,
			metrics.right,
			table.concat(
				(function()
					local reasonParts = {}
					for reason, count in pairs(metrics.reasons) do
						table.insert(reasonParts, reason .. "=" .. count)
					end
					table.sort(reasonParts)
					return reasonParts
				end)(),
				","
			)
		)
	)
end)

joinStream:subscribe(function(pair)
	local leftId = pair.left and pair.left.id or "nil"
	local rightId = pair.right and pair.right.id or "nil"
	print(("[JOIN] left=%s right=%s"):format(leftId, rightId))
end, function(err)
	io.stderr:write(("Join error: %s\n"):format(err))
end, function()
	print("Join stream finished.")
end)
