local SingleGroupDemo = {}

local Query = require("LQR.Query")
local SchemaHelpers = require("tests.support.schema_helpers")
local ZonesTimeline = require("vizualisation.demo.common.zones_timeline")
local Driver = require("vizualisation.demo.common.driver")
local LoveDefaults = require("vizualisation.demo.common.love_defaults")
local Log = require("LQR.util.log").withTag("demo")

local PLAY_DURATION = 12
local demoClock = {
	value = 0,
	now = function(self)
		return self.value or 0
	end,
	set = function(self, v)
		self.value = v or 0
	end,
}

local function build()
	local eventsSubject, events = SchemaHelpers.subjectWithSchema("events", { idField = "id" })

	local builder = Query.from(events, "events")
		:groupBy("events_grouped", function(row)
			-- Group by an event "type" field we inject in payloadForId.
			return row.events.type
		end)
		:groupWindow({ time = 5, field = "sourceTime" })
		:aggregates({
			count = true,
			sum = { "events.value" },
			avg = { "events.value" },
		})
		:having(function(g)
			-- Always emit (threshold=1) so the demo shows activity even with sparse data.
			return (g._count or 0) >= 5
		end)

	return {
		subjects = {
			events = eventsSubject,
		},
		builder = builder,
	}
end

local function buildZones()
	return {
		{
			label = "events_zone",
			schema = "events",
			center = 45,
			range = 1,
			radius = 3,
			shape = "circle10",
			coverage = 1,
			mode = "random",
			rate = 3,
			t0 = 0.05,
			t1 = 0.95,
			rate_shape = "constant",
			idField = "id",
			payloadForId = function(id)
				-- Alternate types for grouping: A/B/C
				local types = { "A", "B", "C" }
				local t = types[(id % #types) + 1]
				return {
					id = id,
					type = t,
					value = 10 + (id % 5) * 5,
				}
			end,
		},
	}
end

local function buildTimeline()
	local zones = buildZones()
	return ZonesTimeline.build(zones, {
		totalPlaybackTime = PLAY_DURATION,
		completeDelay = 0.5,
		grid = { startId = 0, columns = 10, rows = 10 },
		stampSourceTime = true,
		clock = demoClock,
		debug = {
			logger = function(msg)
				Log:debug("%s", msg)
			end,
		},
		snapshots = {
			{ tick = PLAY_DURATION * 0.2, label = "early" },
			{ tick = PLAY_DURATION * 0.6, label = "mid" },
			{ tick = PLAY_DURATION * 0.9, label = "late" },
		},
	})
end

---@return table
function SingleGroupDemo.build()
	return build()
end

---@param subjects table
function SingleGroupDemo.complete(subjects)
	for _, subject in pairs(subjects or {}) do
		if subject.onCompleted then
			subject:onCompleted()
		end
	end
end

---@param subjects table
---@param opts table|nil
---@return table driver
function SingleGroupDemo.start(subjects, opts)
	opts = opts or {}
	local ticksPerSecond = opts.playbackSpeed or opts.ticksPerSecond or 2
	local clock = opts.clock or demoClock
	demoClock = clock
	local events, snapshots, summary = buildTimeline()
	SingleGroupDemo.snapshots = snapshots
	SingleGroupDemo.timeline = events
	SingleGroupDemo.summary = summary

	return Driver.new({
		events = events,
		subjects = subjects,
		ticksPerSecond = ticksPerSecond,
		clock = clock,
		label = "single_group",
		onCompleteAll = SingleGroupDemo.complete,
	})
end

SingleGroupDemo.loveDefaults = LoveDefaults.merge({
	label = "single group",
	visualsTTLFactor = 1.2,
	visualsTTLFactors = {
		source = 1.0,
		joined = 1,
		final = 3,
		expire = 0.02,
	},
	visualsTTLLayerFactors = {
		[1] = 1,
	},
	playbackSpeed = 1.0,
	visualsTTL = 5,
	adjustInterval = 0.25,
	clockMode = "driver",
	clockRate = 1,
	totalPlaybackTime = PLAY_DURATION,
	maxColumns = 10,
	maxRows = 10,
	startId = 0,
	lockWindow = true,
})

return SingleGroupDemo
