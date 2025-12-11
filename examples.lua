-- LiQoR high-level API example
-- Run with: `lua examples.lua` from the repo root.
-- Requires: lua-reactivex checkout at ./reactivex (see README for commands).
package.path = table.concat({
	"./?.lua",
	"./?/init.lua",
	package.path,
}, ";")

local LQR = require("LQR")
local Query = LQR.Query
local get = LQR.get

-- Two simple event logs: lions and gazelles sharing locations.
local lionEvents = {
	-- Arrival / first sightings
	{ id = 1, name = "Nala", sex = "f", hunger = 35, location = "Glade", sourceTime = 1 },
	{ id = 2, name = "Zuri", sex = "f", hunger = 40, location = "Glade", sourceTime = 1 },
	{ id = 3, name = "Mako", sex = "m", hunger = 55, location = "Glade", sourceTime = 1 },
	{ id = 4, name = "Koda", sex = "m", hunger = 60, location = "Glade", sourceTime = 1 },
	-- Steppe moves
	{ id = 5, name = "Nala", sex = "f", hunger = 50, location = "Steppe", sourceTime = 2 },
	{ id = 6, name = "Koda", sex = "m", hunger = 62, location = "Steppe", sourceTime = 2 },
	{ id = 7, name = "Mako", sex = "m", hunger = 65, location = "Steppe", sourceTime = 3 },
	-- Waterhole arrivals
	{ id = 8, name = "Nala", sex = "f", hunger = 55, location = "Waterhole", sourceTime = 4 },
	-- Staying put / later sightings
	{ id = 9, name = "Zuri", sex = "f", hunger = 70, location = "Glade", sourceTime = 5 },
	-- Waterhole arrivals (continued)
	{ id = 10, name = "Koda", sex = "m", hunger = 68, location = "Waterhole", sourceTime = 6 },
	-- Follow-up in Steppe
	{ id = 11, name = "Mako", sex = "m", hunger = 70, location = "Steppe", sourceTime = 7 },
	-- Additional waterhole observations (female lions)
	{ id = 13, name = "Nala", sex = "f", hunger = 60, location = "Waterhole", sourceTime = 9 },
	{ id = 14, name = "Nala", sex = "f", hunger = 70, location = "Waterhole", sourceTime = 10 },
	{ id = 15, name = "Zuri", sex = "f", hunger = 80, location = "Waterhole", sourceTime = 11 },
	{ id = 16, name = "Nala", sex = "f", hunger = 78, location = "Waterhole", sourceTime = 12 },
}

local gazelleEvents = {
	-- Glade sighting
	{ id = 1, location = "Glade", sourceTime = 1 },
	-- Steppe sightings
	{ id = 2, location = "Steppe", sourceTime = 2 },
	{ id = 3, location = "Steppe", sourceTime = 3 },
	-- Waterhole sightings ramp up
	{ id = 4, location = "Waterhole", sourceTime = 4 },
	{ id = 5, location = "Waterhole", sourceTime = 5 },
	-- Back to the glade; then more waterhole traffic
	{ id = 6, location = "Glade", sourceTime = 6 },
	{ id = 7, location = "Waterhole", sourceTime = 7 },
	{ id = 8, location = "Waterhole", sourceTime = 8 },
	{ id = 9, location = "Waterhole", sourceTime = 9 },
	{ id = 10, location = "Steppe", sourceTime = 10 },
	{ id = 11, location = "Waterhole", sourceTime = 11 },
}

-- Use subjects so we can emit after wiring our subscription.
-- In a real app, these subjects would be fed by live events (e.g., LuaEvents or game callbacks).
local SchemaHelpers = require("tests/support/schema_helpers")
local lionsSubject, lions = SchemaHelpers.subjectWithSchema("lions", { idField = "id" })
local gazellesSubject, gazelles = SchemaHelpers.subjectWithSchema("gazelles", { idField = "id" })

-- High-level query: inner join gazelles onto lions by location, then group by location.
local grouped = Query.from(lions, "lions")
	:innerJoin(gazelles, "gazelles")
	:using({ -- Intent: All animals in the same location match. But not need to look at lions again when new gazelles come
		lions = { field = "location", oneshot = true },
		gazelles = { field = "location" },
	})
	:joinWindow({ count = 30 })
	:where(function(row)
		return row.lions.sex == "f"
	end)
	:groupBy("by_location", function(row) -- Intent: We want to have one summary per location in the end
		return row.lions.location
	end)
	:groupWindow({ count = 10 })
	:aggregates({
		count = {
			{
				path = "gazelles.id",
				distinctFn = function(row)
					return row.gazelles.id
				end,
			},
		},
		avg = {
			{
				path = "lions.hunger",
				distinctFn = function(row)
					return row.lions.name
				end,
			},
		},
		max = {
			{ path = "lions.sourceTime" },
		},
	})
	:having(function(row)
		-- Emit all groups for demo visibility.
		return (get(row, "gazelles._count.id") or 0) >= 2
	end)

print("LiQoR example: Observations of lions and gazelles grouped by location\n")

grouped:subscribe(function(row)
	print(
		("[AGG] loc=%s | Log entry No=%s | gazelles=%s | Lions Hunger=%.1f | Lions are %s"):format(
			row._group_key,
			row.lions._max.sourceTime,
			row.gazelles._count.id,
			row.lions._avg.hunger,

			row.lions._avg.hunger >= 70 and "Hunting!" or "zZ sleeping .."
		)
	)
end, function(err)
	print("Error:", err)
end, function()
	print("\nDone.")
end)

-- Simulate events coming in live
-- Emit after subscriptions are wired, interleaving by sourceTime so join windows see both sides together.
local li, gi = 1, 1
while li <= #lionEvents or gi <= #gazelleEvents do
	local lion = lionEvents[li]
	local gazelle = gazelleEvents[gi]
	local lionTime = lion and lion.sourceTime or math.huge
	local gazelleTime = gazelle and gazelle.sourceTime or math.huge

	if gazelle == nil or (lion and lionTime <= gazelleTime) then
		lionsSubject:onNext(lion)
		li = li + 1
	else
		gazellesSubject:onNext(gazelle)
		gi = gi + 1
	end
end
lionsSubject:onCompleted()
gazellesSubject:onCompleted()

-- Kick the cooperative scheduler so cold fromTable sources emit.
LQR.rx.scheduler.start()
