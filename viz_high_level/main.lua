local QueryVizAdapter = require("viz_high_level.query_adapter")
local Runtime = require("viz_high_level.runtime")

local HighLevelViz = {}

---Attaches high-level viz runtime to a QueryBuilder.
---@param builder table QueryBuilder instance
---@param opts table|nil { maxLayers, palette, runtimeOpts, now }
---@return table { runtime, attachment, subscription }
function HighLevelViz.attach(builder, opts)
	opts = opts or {}
	local nowFn = opts.now or os.clock
	local attachment = QueryVizAdapter.attach(builder, {
		maxLayers = opts.maxLayers,
		palette = opts.palette,
	})

	local runtime = Runtime.new({
		maxLayers = attachment.maxLayers,
		palette = attachment.palette,
		now = nowFn(),
	})

	local subscription = attachment.normalized:subscribe(function(event)
		runtime:ingest(event, nowFn())
	end)

	return {
		runtime = runtime,
		attachment = attachment,
		subscription = subscription,
	}
end

return HighLevelViz
