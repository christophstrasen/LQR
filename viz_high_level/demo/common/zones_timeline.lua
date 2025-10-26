local ZonesTimeline = {}

local Zones = require("viz_high_level.zones")

---Build events and snapshots from zones with a deterministic completion marker.
---@param zones table[]
---@param opts table
---@return table events
---@return table snapshots
---@return table summary
function ZonesTimeline.build(zones, opts)
	opts = opts or {}
	local totalPlaybackTime = opts.totalPlaybackTime or 10
	local playStart = opts.playStart or 0

	local events, summary = Zones.generator.generate(zones or {}, {
		totalPlaybackTime = totalPlaybackTime,
		playStart = playStart,
	})

	events[#events + 1] = { tick = playStart + totalPlaybackTime + (opts.completeDelay or 0.5), kind = "complete" }

	local snapshots = opts.snapshots or {
		{ tick = playStart + (totalPlaybackTime * 0.25), label = "early" },
		{ tick = playStart + (totalPlaybackTime * 0.6), label = "mid" },
		{ tick = playStart + (totalPlaybackTime * 0.95), label = "late" },
	}

	return events, snapshots, summary
end

return ZonesTimeline
