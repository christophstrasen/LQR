-- Walks through consuming the expired stream to build simple eviction metrics.
-- Use it as a template whenever you need visibility into why records fall out of the cache.

-- Expected console: a couple of join lines plus a METRICS summary counting evictions by side/reason.
require("bootstrap")
local io = require("io")

local rx = require("reactivex")
local JoinObservable = require("JoinObservable")
local Schema = require("JoinObservable.schema")

local leftStream = Schema.wrap("leftMetrics", rx.Observable.fromTable({
	{ id = 1, payload = "left-1" },
	{ id = 2, payload = "left-2" },
	{ id = 3, payload = "left-3" },
}, ipairs), "leftMetrics")

local rightStream = Schema.wrap("rightMetrics", rx.Observable.fromTable({
	{ id = 1, payload = "right-1" },
	{ id = 2, payload = "right-2" },
	{ id = 4, payload = "right-4" },
}, ipairs), "rightMetrics")

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
	reasons = {},
	aliases = {},
}

expiredStream:subscribe(function(packet)
	local alias = packet.alias or "unknown"
	metrics.total = metrics.total + 1
	metrics.aliases[alias] = (metrics.aliases[alias] or 0) + 1
	metrics.reasons[packet.reason] = (metrics.reasons[packet.reason] or 0) + 1
	local entry = packet.result and packet.result:get(alias)
	print(
		("[EXPIRED] alias=%s id=%s reason=%s"):format(
			alias,
			entry and entry.id or "nil",
			packet.reason
		)
	)
end, function(err)
	io.stderr:write(("Expired stream error: %s\n"):format(err))
end, function()
	print(
		("[METRICS] Expired total=%d aliases=%s reasons=%s"):format(
			metrics.total,
			(function()
				local aliasParts = {}
				for alias, count in pairs(metrics.aliases) do
					table.insert(aliasParts, alias .. "=" .. count)
				end
				table.sort(aliasParts)
				return table.concat(aliasParts, ",")
			end)(),
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

joinStream:subscribe(function(result)
	local left = result:get("leftMetrics")
	local right = result:get("rightMetrics")
	local leftId = left and left.id or "nil"
	local rightId = right and right.id or "nil"
	print(("[JOIN] left=%s right=%s"):format(leftId, rightId))
end, function(err)
	io.stderr:write(("Join error: %s\n"):format(err))
end, function()
	print("Join stream finished.")
end)
