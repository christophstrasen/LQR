-- Illustrates supplying a custom merge observable to control arrival order explicitly.
-- Reach for this any time upstream ordering matters (e.g., you must process rights first).

-- Expected console: MERGE lines show right records forwarded first, then join matches for ids 1 and 2.
require("bootstrap")
local io = require("io")

local rx = require("reactivex")
local JoinObservable = require("JoinObservable")
local Schema = require("JoinObservable.schema")

local leftStream = Schema.wrap("customers", rx.Observable.fromTable({
	{ id = 1, side = "left", note = "would normally arrive first" },
	{ id = 2, side = "left", note = "still left" },
}), "customers")

local rightStream = Schema.wrap("payments", rx.Observable.fromTable({
	{ id = 1, side = "right", note = "right events" },
	{ id = 2, side = "right", note = "another right" },
}), "payments")

local function rightFirstMerge(leftTagged, rightTagged)
	-- `fromTable` emits synchronously, so the default `merge` would drain the entire
	-- left stream before the right ever gets a chance. This custom merge forces a
	-- deliberate ordering so we can observe how the join honors manual interleaving.
	local function inspect(observable)
		-- Map each tagged record so the console shows which side the merge forwards first.
		return observable:map(function(record)
			local entry = record.entry or {}
			print(("[MERGE] forwarding %s id=%s"):format(record.side, entry.id or "nil"))
			return record
		end)
	end

	-- Concatenating the tagged observables means right entries are forwarded in full
	-- before any left entries. The join will therefore see right ids first even
	-- though both sources are synchronous.
	return rx.Observable.concat(inspect(rightTagged), inspect(leftTagged))
end

local joinStream = JoinObservable.createJoinObservable(leftStream, rightStream, {
	on = "id",
	joinType = "inner",
	merge = rightFirstMerge, -- Custom merge enforces a deterministic right-before-left ordering.
})

joinStream:subscribe(function(result)
	local leftRecord = result:get("customers")
	if leftRecord then
		print(("[JOIN] matched id=%d"):format(leftRecord.id))
	end
end, function(err)
	io.stderr:write(("Join error: %s\n"):format(err))
end, function()
	print("Join stream finished.")
end)
