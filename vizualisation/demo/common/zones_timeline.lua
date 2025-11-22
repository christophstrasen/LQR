local ZonesTimeline = {}

local Zones = require("vizualisation.zones")

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

	local genOpts = {
		totalPlaybackTime = totalPlaybackTime,
		playStart = playStart,
		grid = opts.grid,
		stampSourceTime = opts.stampSourceTime,
		clock = opts.clock,
	}
	local events, summary = Zones.generator.generate(zones or {}, genOpts)

	events[#events + 1] = { tick = playStart + totalPlaybackTime + (opts.completeDelay or 0.5), kind = "complete" }

	local snapshots = opts.snapshots or {
		{ tick = playStart + (totalPlaybackTime * 0.25), label = "early" },
		{ tick = playStart + (totalPlaybackTime * 0.6), label = "mid" },
		{ tick = playStart + (totalPlaybackTime * 0.95), label = "late" },
	}

	return events, snapshots, summary
end

return ZonesTimeline
