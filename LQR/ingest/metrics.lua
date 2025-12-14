local function deepCopy(tbl)
	local out = {}
	for k, v in pairs(tbl) do
		if type(v) == "table" then
			out[k] = deepCopy(v)
		else
			out[k] = v
		end
	end
	return out
end

local function new(name)
	return {
		name = name or "ingest",
		totals = {
			ingestedTotal = 0,
			enqueuedTotal = 0,
			dedupedTotal = 0,
			replacedTotal = 0,
			droppedTotal = 0,
			drainedTotal = 0,
			drainCallsTotal = 0,
		},
		droppedByReason = {},
		pending = 0,
		peakPending = 0,
		lastDrain = {},
		-- Span of ingestSeq for items currently pending (exact when computed by the buffer).
		oldestSeq = nil,
		newestSeq = nil,
		ingestSeqSpan = 0,
		avgPending = 0,
		avgSeqSpan = 0,
		avgCount = 0,
		emaPending = nil,
		emaSeqSpan = nil,
		emaAlpha = 0.2,
		perLane = {},
		load1 = 0,
		load5 = 0,
		load15 = 0,
		throughput1 = 0,
		throughput5 = 0,
		throughput15 = 0,
		ingestRate1 = 0,
		ingestRate5 = 0,
		ingestRate15 = 0,
		msPerItemEma = nil,
		lastLoadAtMs = nil,
		lastDtSeconds = nil,
	}
end

local Metrics = {}

function Metrics.new(name)
	return new(name)
end

function Metrics.reset(state)
	state.totals = new(state.name).totals
	state.droppedByReason = {}
	state.pending = state.pending
	state.peakPending = state.pending
	state.lastDrain = {}
	state.oldestSeq = nil
	state.newestSeq = nil
	state.ingestSeqSpan = 0
	state.avgPending = 0
	state.avgSeqSpan = 0
	state.avgCount = 0
	state.emaPending = nil
	state.emaSeqSpan = nil
	state.perLane = {}
	state.load1 = 0
	state.load5 = 0
	state.load15 = 0
	state.throughput1 = 0
	state.throughput5 = 0
	state.throughput15 = 0
	state.ingestRate1 = 0
	state.ingestRate5 = 0
	state.ingestRate15 = 0
	state.msPerItemEma = nil
	state.lastLoadAtMs = nil
	state.lastDtSeconds = nil
end

function Metrics.bumpPending(state, delta, lane)
	state.pending = state.pending + delta
	if state.pending > state.peakPending then
		state.peakPending = state.pending
	end
	if lane then
		local laneMetrics = state.perLane[lane] or { pending = 0, peakPending = 0, drainedTotal = 0, droppedTotal = 0, seqSpan = 0 }
		laneMetrics.pending = laneMetrics.pending + delta
		if laneMetrics.pending > laneMetrics.peakPending then
			laneMetrics.peakPending = laneMetrics.pending
		end
		state.perLane[lane] = laneMetrics
	end
end

function Metrics.bumpTotal(state, key, delta)
	state.totals[key] = (state.totals[key] or 0) + (delta or 1)
end

function Metrics.bumpDropReason(state, reason)
	state.droppedByReason[reason] = (state.droppedByReason[reason] or 0) + 1
end

function Metrics.bumpLaneDrained(state, lane, count)
	local laneMetrics = state.perLane[lane] or { pending = 0, peakPending = 0, drainedTotal = 0, droppedTotal = 0, seqSpan = 0 }
	laneMetrics.drainedTotal = laneMetrics.drainedTotal + count
	state.perLane[lane] = laneMetrics
end

function Metrics.bumpLaneDropped(state, lane, count)
	local laneMetrics = state.perLane[lane] or { pending = 0, peakPending = 0, drainedTotal = 0, droppedTotal = 0, seqSpan = 0 }
	laneMetrics.droppedTotal = laneMetrics.droppedTotal + count
	state.perLane[lane] = laneMetrics
end

function Metrics.updateLastDrain(state, snapshot)
	state.lastDrain = snapshot
end

function Metrics.snapshot(state, _lanes, spanOverride)
	local oldestSeq = spanOverride and spanOverride.oldestSeq or state.oldestSeq
	local newestSeq = spanOverride and spanOverride.newestSeq or state.newestSeq
	local span = spanOverride and spanOverride.ingestSeqSpan
	if span == nil then
		span = state.ingestSeqSpan or 0
	end
	local snap = {
		name = state.name,
		pending = state.pending,
		peakPending = state.peakPending,
		ingestSeqSpan = span,
		oldestSeq = oldestSeq,
		newestSeq = newestSeq,
		totals = deepCopy(state.totals),
		droppedByReason = deepCopy(state.droppedByReason),
		lastDrain = deepCopy(state.lastDrain),
		avgPending = state.avgPending,
		avgSeqSpan = state.avgSeqSpan,
		perLane = deepCopy(state.perLane),
		load1 = state.load1,
		load5 = state.load5,
		load15 = state.load15,
		throughput1 = state.throughput1,
		throughput5 = state.throughput5,
		throughput15 = state.throughput15,
		ingestRate1 = state.ingestRate1,
		ingestRate5 = state.ingestRate5,
		ingestRate15 = state.ingestRate15,
		msPerItemEma = state.msPerItemEma,
		lastDtSeconds = state.lastDtSeconds,
	}
	return snap
end

function Metrics.snapshotLight(state)
	return {
		name = state.name,
		pending = state.pending,
		peakPending = state.peakPending,
		totals = deepCopy(state.totals),
		lastDrain = deepCopy(state.lastDrain),
		load1 = state.load1,
		load5 = state.load5,
		load15 = state.load15,
		throughput1 = state.throughput1,
		throughput5 = state.throughput5,
		throughput15 = state.throughput15,
		ingestRate1 = state.ingestRate1,
		ingestRate5 = state.ingestRate5,
		ingestRate15 = state.ingestRate15,
		msPerItemEma = state.msPerItemEma,
		lastDtSeconds = state.lastDtSeconds,
	}
end

function Metrics.accumulateAverages(state, seqSpan)
	state.avgCount = state.avgCount + 1
	local n = state.avgCount
	state.avgPending = state.avgPending + ((state.pending - state.avgPending) / n)
	state.avgSeqSpan = state.avgSeqSpan + (((seqSpan or 0) - state.avgSeqSpan) / n)
	if state.emaPending == nil then
		state.emaPending = state.pending
		state.emaSeqSpan = seqSpan or 0
	else
		local a = state.emaAlpha
		state.emaPending = (a * state.pending) + ((1 - a) * state.emaPending)
		state.emaSeqSpan = (a * (seqSpan or 0)) + ((1 - a) * state.emaSeqSpan)
	end
end

local function resolveNowMillis(nowMillisFn)
	if type(nowMillisFn) == "function" then
		local v = nowMillisFn()
		if type(v) == "number" then
			return v
		end
	end
	if type(os.clock) == "function" then
		return os.clock() * 1000
	end
	return nil
end

function Metrics.updateLoad(state, pendingSample, processedSample, ingestedSample, nowMillisFn)
	local nowMs = resolveNowMillis(nowMillisFn)
	if type(nowMs) ~= "number" then
		return
	end
	if not state.lastLoadAtMs then
		state.lastLoadAtMs = nowMs
		state.load1 = pendingSample or 0
		state.load5 = pendingSample or 0
		state.load15 = pendingSample or 0
		local rate = processedSample or 0
		state.throughput1 = rate
		state.throughput5 = rate
		state.throughput15 = rate
		local ingestRate = ingestedSample or 0
		state.ingestRate1 = ingestRate
		state.ingestRate5 = ingestRate
		state.ingestRate15 = ingestRate
		state.lastDtSeconds = nil
		return
	end

	local dtSeconds = (nowMs - state.lastLoadAtMs) / 1000
	if dtSeconds <= 0 then
		return
	end

	local function updateEwma(prev, sample, windowSeconds)
		local expFactor = math.exp(-dtSeconds / windowSeconds)
		return (prev or sample) * expFactor + sample * (1 - expFactor)
	end

	state.load1 = updateEwma(state.load1, pendingSample or 0, 1)
	state.load5 = updateEwma(state.load5, pendingSample or 0, 5)
	state.load15 = updateEwma(state.load15, pendingSample or 0, 15)

	local rate = (processedSample or 0) / dtSeconds
	state.throughput1 = updateEwma(state.throughput1, rate, 1)
	state.throughput5 = updateEwma(state.throughput5, rate, 5)
	state.throughput15 = updateEwma(state.throughput15, rate, 15)

	local ingestRate = (ingestedSample or 0) / dtSeconds
	state.ingestRate1 = updateEwma(state.ingestRate1, ingestRate, 1)
	state.ingestRate5 = updateEwma(state.ingestRate5, ingestRate, 5)
	state.ingestRate15 = updateEwma(state.ingestRate15, ingestRate, 15)

	state.lastLoadAtMs = nowMs
	state.lastDtSeconds = dtSeconds
end

function Metrics.updateMsPerItem(state, msPerItem)
	if type(msPerItem) ~= "number" or msPerItem <= 0 then
		return
	end
	local a = state.emaAlpha or 0.2
	if not state.msPerItemEma then
		state.msPerItemEma = msPerItem
	else
		state.msPerItemEma = (a * msPerItem) + ((1 - a) * state.msPerItemEma)
	end
end

return Metrics
