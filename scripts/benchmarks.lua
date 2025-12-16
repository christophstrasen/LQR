local package = require("package")
package.path = "./?.lua;" .. package.path
package.cpath = "./?.so;" .. package.cpath

require("LQR/bootstrap")

local LQR = require("LQR")
local Ingest = require("LQR/ingest")
local Log = require("LQR/util/log")

local Query = LQR.Query
local Schema = LQR.Schema
local rx = LQR.rx

local function parseArgs(argv)
	local out = {
		ci = false,
		runs = 1,
		n = 20000,
		joinWindow = 2000,
		groupWindow = 50,
		groupKeys = 200,
		ingestCapacity = 2000,
		ingestN = 2000,
	}

	for i = 1, (argv and #argv or 0) do
		local token = argv[i]
		if token == "--ci" then
			out.ci = true
		elseif token:match("^%-%-runs=") then
			out.runs = tonumber(token:match("^%-%-runs=(%d+)$")) or out.runs
		elseif token:match("^%-%-n=") then
			out.n = tonumber(token:match("^%-%-n=(%d+)$")) or out.n
		elseif token:match("^%-%-joinWindow=") then
			out.joinWindow = tonumber(token:match("^%-%-joinWindow=(%d+)$")) or out.joinWindow
		elseif token:match("^%-%-groupWindow=") then
			out.groupWindow = tonumber(token:match("^%-%-groupWindow=(%d+)$")) or out.groupWindow
		elseif token:match("^%-%-groupKeys=") then
			out.groupKeys = tonumber(token:match("^%-%-groupKeys=(%d+)$")) or out.groupKeys
		elseif token:match("^%-%-ingestCapacity=") then
			out.ingestCapacity = tonumber(token:match("^%-%-ingestCapacity=(%d+)$")) or out.ingestCapacity
		elseif token:match("^%-%-ingestN=") then
			out.ingestN = tonumber(token:match("^%-%-ingestN=(%d+)$")) or out.ingestN
		end
	end

	if out.ci then
		out.runs = 1
		out.n = math.min(out.n, 5000)
		out.joinWindow = math.min(out.joinWindow, 1500)
		out.groupWindow = math.min(out.groupWindow, 50)
		out.groupKeys = math.min(out.groupKeys, 200)
		out.ingestN = math.min(out.ingestN, out.ingestCapacity)
	end

	return out
end

local function bench(name, fn)
	collectgarbage("collect")
	local start = os.clock()
	local stats = fn() or {}
	local elapsed = os.clock() - start
	stats.name = name
	stats.seconds = elapsed
	return stats
end

local function printResult(stats)
	local nIn = tonumber(stats.inCount or 0) or 0
	local nOut = tonumber(stats.outCount or 0) or 0
	local seconds = tonumber(stats.seconds or 0) or 0
	local perOutUs = seconds > 0 and (seconds * 1000000 / math.max(nOut, 1)) or 0
	local outPerSec = seconds > 0 and (nOut / seconds) or 0

	print(
		string.format(
			"BENCH %-18s in=%d out=%d seconds=%.6f usPerOut=%.2f outPerSec=%.1f",
			tostring(stats.name),
			nIn,
			nOut,
			seconds,
			perOutUs,
			outPerSec
		)
	)
end

local function buildSubject(schemaName)
	local subject = rx.Subject.create()
	local wrapped = Schema.wrap(schemaName, subject, { idField = "id" })
	return subject, wrapped
end

local function benchLeanQuery(n)
	local subject, stream = buildSubject("events")
	local outCount = 0

	local query = Query.from(stream, "events"):where(function(row)
		return (row.events.id % 2) == 0
	end)

	query:subscribe(function()
		outCount = outCount + 1
	end)

	for i = 1, n do
		subject:onNext({ id = i, sourceTime = i })
	end

	return { inCount = n, outCount = outCount }
end

local function benchTwoJoins(n, joinWindow)
	local aSub, a = buildSubject("a")
	local bSub, b = buildSubject("b")
	local cSub, c = buildSubject("c")

	local outCount = 0

	local query = Query.from(a, "a")
		:innerJoin(b, "b")
		:using({ a = "id", b = "id" })
		:joinWindow({ count = joinWindow, gcOnInsert = true })
		:innerJoin(c, "c")
		:using({ a = "id", c = "id" })
		:joinWindow({ count = joinWindow, gcOnInsert = true })

	query:subscribe(function()
		outCount = outCount + 1
	end)

	for i = 1, n do
		aSub:onNext({ id = i, sourceTime = i })
		bSub:onNext({ id = i, sourceTime = i })
		cSub:onNext({ id = i, sourceTime = i })
	end

	return { inCount = n * 3, outCount = outCount }
end

local function benchThreeJoins(n, joinWindow)
	local aSub, a = buildSubject("a")
	local bSub, b = buildSubject("b")
	local cSub, c = buildSubject("c")
	local dSub, d = buildSubject("d")

	local outCount = 0

	local query = Query.from(a, "a")
		:innerJoin(b, "b")
		:using({ a = "id", b = "id" })
		:joinWindow({ count = joinWindow, gcOnInsert = true })
		:innerJoin(c, "c")
		:using({ a = "id", c = "id" })
		:joinWindow({ count = joinWindow, gcOnInsert = true })
		:innerJoin(d, "d")
		:using({ a = "id", d = "id" })
		:joinWindow({ count = joinWindow, gcOnInsert = true })

	query:subscribe(function()
		outCount = outCount + 1
	end)

	for i = 1, n do
		aSub:onNext({ id = i, sourceTime = i })
		bSub:onNext({ id = i, sourceTime = i })
		cSub:onNext({ id = i, sourceTime = i })
		dSub:onNext({ id = i, sourceTime = i })
	end

	return { inCount = n * 4, outCount = outCount }
end

local function benchGroupBy(n, windowCount, keyCount)
	local customersSub, customers = buildSubject("customers")
	local outCount = 0

	local grouped = Query.from(customers, "customers")
		:groupByEnrich("_groupBy:customers", function(row)
			return row.customers.groupId
		end)
		:groupWindow({ count = windowCount })
		:aggregates({
			row_count = true,
			sum = { "customers.value" },
		})

	grouped:subscribe(function()
		outCount = outCount + 1
	end)

	for i = 1, n do
		local groupId = (i % keyCount) + 1
		customersSub:onNext({ id = i, groupId = groupId, value = (i % 100) })
	end

	return { inCount = n, outCount = outCount }
end

local function benchIngestPipeline(n, capacity)
	local buffer = Ingest.buffer({
		name = "bench.ingest",
		mode = "queue",
		capacity = capacity,
		key = function(item)
			return item.id
		end,
	})

	local scheduler = Ingest.scheduler({ name = "bench.scheduler", maxItemsPerTick = 200 })
	scheduler:addBuffer(buffer, { priority = 1 })

	for i = 1, n do
		buffer:ingest({ id = i })
	end

	local processed = 0
	while true do
		local stats = scheduler:drainTick(function(_)
			processed = processed + 1
		end)
		local pending = stats and stats.pending or 0
		if pending <= 0 then
			break
		end
		if (stats.processed or 0) <= 0 then
			break
		end
	end

	return { inCount = n, outCount = processed }
end

local function runOne(opts)
	local results = {}
	results[#results + 1] = bench("lean_query", function()
		return benchLeanQuery(opts.n)
	end)
	results[#results + 1] = bench("join_2", function()
		return benchTwoJoins(opts.n, opts.joinWindow)
	end)
	results[#results + 1] = bench("join_3", function()
		return benchThreeJoins(opts.n, opts.joinWindow)
	end)
	results[#results + 1] = bench("group_by", function()
		return benchGroupBy(opts.n, opts.groupWindow, opts.groupKeys)
	end)
	results[#results + 1] = bench("ingest", function()
		return benchIngestPipeline(opts.ingestN, opts.ingestCapacity)
	end)
	return results
end

local opts = parseArgs(arg or {})

-- Benchmarks should be quiet besides their own summary lines.
Log.setLevel("warn")

print(
	string.format(
		"benchmarks lua=5.1 runs=%d n=%d joinWindow=%d groupWindow=%d groupKeys=%d ingestN=%d ingestCapacity=%d",
		tonumber(opts.runs or 1) or 1,
		tonumber(opts.n or 0) or 0,
		tonumber(opts.joinWindow or 0) or 0,
		tonumber(opts.groupWindow or 0) or 0,
		tonumber(opts.groupKeys or 0) or 0,
		tonumber(opts.ingestN or 0) or 0,
		tonumber(opts.ingestCapacity or 0) or 0
	)
)

for run = 1, (opts.runs or 1) do
	print(string.format("run=%d", run))
	local results = runOne(opts)
	for i = 1, #results do
		printResult(results[i])
	end
end

print("PZ usage: require('examples/lqr_benchmarks').start({ ci = true })")
