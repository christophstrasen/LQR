-- Headless helper: ingest a normalized event trace and print window snapshots.
package.path = "./?.lua;./?/init.lua;" .. package.path

local Runtime = require("viz_high_level.runtime")

local trace = {
	{ t = 0.0, event = { type = "source", schema = "customers", id = 10 } },
	{ t = 0.1, event = { type = "source", schema = "orders", id = 101 } },
	{ t = 0.2, event = { type = "match", layer = 2, key = 10, left = { schema = "customers", id = 10 }, right = { schema = "orders", id = 101 } } },
	{ t = 1.5, event = { type = "source", schema = "customers", id = 40 } },
	{ t = 2.5, event = { type = "match", layer = 1, key = 101, left = { schema = "orders", id = 101 }, right = { schema = "refunds", id = 201 } } },
	{ t = 3.0, event = { type = "expire", layer = 1, schema = "orders", id = 999, reason = "evicted" } },
}

local runtime = Runtime.new({ maxLayers = 5, maxColumns = 16, maxRows = 2, adjustInterval = 1 })

for _, entry in ipairs(trace) do
	runtime:ingest(entry.event, entry.t)
	local window = runtime:window()
	print(string.format(
		"t=%.2f window=[%s,%s] sources=%d matches=%d expires=%d",
		entry.t,
		tostring(window.startId),
		tostring(window.endId),
		#runtime.events.source,
		#runtime.events.match,
		#runtime.events.expire
	))
end
