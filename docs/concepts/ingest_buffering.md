# Ingest buffering (Ingest → Buffer → Drain)

LQR and lua-reactivex are *push-based*: when an event arrives, it is immediately pushed to subscribers.
In tick-driven runtimes (games, sims, some UI loops) this can be a problem:

- sources can be **bursty** (hundreds/thousands of events in one frame); and
- downstream work (schema wrapping, joins, grouping, callbacks) can be **non-trivial**.

`LQR/ingest` is a small, host-friendly “admission control” layer that sits **before** schemas and queries:

1. **Ingest** (cheap, in the event handler)
2. **Buffer** (bounded memory, explicit overflow/compaction)
3. **Drain** (budgeted work per tick)

The goal is simple: keep event handlers predictable, and do the expensive work on your own cadence.

---

## The mental model

You usually end up with code like this:

- Event handler: “something happened” → call `buffer:ingest(item)`.
- Tick loop: “do some work this frame” → call `buffer:drain({ maxItems = N, ... })`.

That’s it. The buffer becomes the boundary where you decide:

- how much you keep in memory (`capacity`);
- how duplicates may be compacted (`mode`);
- how to prioritize different kinds of work (`lane` + `lanePriority`);
- how much you do per tick (`maxItems`, optionally `maxMillis`); and
- how to observe overload (`metrics_get`, hooks).

---

## Basic usage

This example simulates two “sources” feeding one buffer, and a host tick draining it:

```lua
local Ingest = require("LQR/ingest")

local buffer = Ingest.buffer({
  name = "world.squares",
  mode = "dedupSet",      -- "dedupSet" | "latestByKey" | "queue"
  ordering = "fifo",      -- only used for dedupSet/latestByKey
  capacity = 5000,
  key = function(item) return item.squareId end,

  -- Optional: assign items to lanes (domain-defined labels).
  lane = function(item)
    if item.kind == "ZombieKilled" then
      return "combat.urgent"
    end
    return "world.background"
  end,

  -- Optional: higher number drains first (starts at 1).
  lanePriority = function(laneName)
    if laneName == "combat.urgent" then return 2 end
    return 1
  end,
})

-- “Source 1”: bursty engine events
local function onSquareLoaded(squareId)
  buffer:ingest({ kind = "LoadSquare", squareId = squareId })
end

-- “Source 2”: an external event feed
local function onZombieKilled(squareId)
  buffer:ingest({ kind = "ZombieKilled", squareId = squareId })
end

-- Host tick (called once per frame / tick)
local function onTick()
  buffer:drain({
    maxItems = 200,
    handle = function(item)
      -- Do the expensive work here (materialize/lookup/emit downstream).
      -- Often: turn a lightweight key into a full record before pushing it.
    end,
  })
end
```

See an executable end-to-end test in `tests/unit/ingest_end_to_end_spec.lua`.

---

## Modes: how buffering behaves

All modes are bounded by `capacity` (global across lanes).

### `dedupSet` (unique pending keys)

- Keeps each key at most once while pending.
- Re-ingesting a pending key is a no-op (except it updates `lastSeen` for eviction fairness).
- Best for “coverage / refresh” work where duplicates are common and harmless.

### `latestByKey` (one payload per key)

- Keeps one item per key and **replaces** it when the key is ingested again.
- Best for “current state” updates (“only the latest matters”).

### `queue` (bounded FIFO)

- Keeps a FIFO of items (per lane).
- Default overflow behavior: drop oldest from the losing lane.
- Best when **history** matters (rarer for state observation).

---

## Lanes: bias, priority, and fairness (v1)

Lanes let you express “this kind of item is more important” without encoding domain policy into LQR.

- `lane(item) -> string|nil`: returns a label; `nil` becomes `"default"`.
- `lanePriority(laneName) -> integer`: priorities start at `1`; higher drains first.

In v1:

- draining is strict priority (higher priority first); and
- overflow eviction picks the **lowest** priority lane (round-robin on ties).

---

## Budgets: `maxItems` and optional `maxMillis`

`maxItems` is always deterministic and recommended.

`maxMillis` is optional and requires a reliable, monotonic `nowMillis()`:

```lua
buffer:drain({
  maxItems = 500,
  maxMillis = 2,
  nowMillis = function() return myClockMillis() end,
  handle = function(item) ... end,
})
```

If `nowMillis()` is missing/bad/non-monotonic or `maxMillis <= 0`, drain processes 0 items and warns.

---

## Metrics and hooks

Use pull-based metrics for cheap observability:

- `buffer:metrics_get()` returns counters/peaks + per-lane summaries.
- `buffer:metrics_reset()` resets counters without clearing buffered items.
- `buffer:clear()` clears buffered items without resetting historical totals.

### Load averages (1s / 5s / 15s)

Ingress also maintains “load average”-style metrics inspired by Linux `top`:

- `load1`, `load5`, `load15`: EWMA of `pendingAfter` (buffer backlog pressure)
- `throughput1`, `throughput5`, `throughput15`: EWMA of drained items per second
- `ingestRate1`, `ingestRate5`, `ingestRate15`: EWMA of ingested items per second (arrival rate)

These numbers let you see trend at a glance:

- `load1 > load5 > load15` → backlog is rising (you are falling behind)
- `load1 < load5 < load15` → backlog is falling (you are catching up)
- short spikes in `load1` with stable `load15` → transient bursts

Implementation notes:

- The windows are **seconds** (defaults: 1s / 5s / 15s).
- They are updated once per `buffer:drain(...)` call.
- If you pass `nowMillis` to `drain`, it is used for timing; otherwise a monotonic fallback (`os.clock`) is used for deltas.

### Practical use: “am I keeping up?”

The simplest health check is whether you drain at least as fast as events arrive:

- if `throughput15 >= ingestRate15` and `load15` stays small → you are stable
- if `throughput15 < ingestRate15` and `load15` grows → you are falling behind

---

## Budget advice (`buffer:advice_get`)

To avoid re-deriving rates and doing tick math in every host, the buffer can produce a simple “nudge” based on its recent behavior:

### Example: adaptive on-tick drain

This is a typical tick-loop pattern:

- ingest cheaply in event handlers; then
- on each tick, consult `advice_get()` and adjust the next drain budget gradually.

```lua
local Ingest = require("LQR/ingest")

local buffer = Ingest.buffer({
  name = "engine.events",
  mode = "dedupSet",
  capacity = 5000,
  ordering = "fifo",
  key = function(item) return item.id end,
})

-- Budget that we adapt over time (items per tick).
local maxItems = 200
local minItems = 50
local maxItemsCap = 2000

-- A clock for rate/advice calculations (milliseconds).
-- In many hosts you have a better clock; `os.clock()` is a portable fallback.
local function nowMillis()
  return os.clock() * 1000
end

-- Event handler(s): keep this cheap.
function onEvent(id)
  buffer:ingest({ id = id })
end

-- Host tick (e.g. each frame at ~60fps).
function onTick()
  local advice = buffer:advice_get({
    -- Omit for steady-state recommendations (keep up with arrivals).
    -- Set to add a catch-up term for existing backlog:
    -- recommendedThroughput ≈ ingestRate15 + load15/targetClearSeconds
  targetClearSeconds = 10,
})

-- Smooth + clamp in one call.
maxItems, advice = buffer:advice_applyMaxItems(maxItems, {
  alpha = 0.2,          -- optional smoothing (0..1, higher reacts faster)
  minItems = minItems,  -- optional floor
  maxItems = maxItemsCap, -- optional cap
  targetClearSeconds = 10, -- reuse the same horizon inside advice_get
})

  -- Do bounded work this tick.
  buffer:drain({
    maxItems = maxItems,
    nowMillis = nowMillis, -- optional but improves rate estimates
    handle = function(item)
      -- Materialize / emit downstream work here.
      -- Keep this function free of unbounded loops.
    end,
  })
end
```

```lua
local advice = buffer:advice_get({
  targetClearSeconds = 15, -- optional: how quickly to “eat into” existing backlog
})

print(advice.trend)               -- "rising" | "falling" | "steady"
print(advice.recommendedMaxItems) -- integer (or nil if dt is unknown)
```

What it does:

- estimates arrival rate (`ingestRate15`) and drain rate (`throughput15`);
- classifies a coarse trend (rising/falling/steady); and
- recommends a `maxItems` for the *next* `drain(...)` call using the observed drain interval (`dt`).

How `targetClearSeconds` works:

- If you omit it, advice aims for *steady state* (drain roughly as fast as items arrive).
- If you set it, advice adds a catch-up term based on current backlog:
  `recommendedThroughput ≈ ingestRate15 + (load15 / targetClearSeconds)`.
  Smaller values mean “catch up faster” (more aggressive budgets); larger values mean “catch up slowly”.

Typical host usage:

- Call `buffer:drain(...)` once per frame/tick with a current budget.
- If `advice.trend == "rising"`, increase `maxItems` gradually (or raise `maxMillis` if you use time budgets).
- If `advice.trend == "steady"` and `load15` is low, keep budgets conservative.

Note: advice is only as good as your drain cadence. If you drain irregularly, pass a stable interval via `buffer:advice_get({ drainIntervalSeconds = ... })`.

`advice_applyMaxMillis` also exists, but requires timing data (you must pass `nowMillis` and have observed `spentMillis` in drains). When timing data is missing, it will warn and leave your budget unchanged.

Use hooks when you want immediate visibility:

- `onDrop({ reason, key, lane, item? })` (e.g. overflow, badKey)
- `onReplace({ old, new, key, lane })`
- `onDrainStart(...)` / `onDrainEnd(...)`

---

## How this relates to LQR operators

Ingress buffering is intentionally **pre-schema** and “source-boundary” oriented:

- It decides *what work is admitted* and *how much runs per tick*.
- It does **not** decide query semantics.

Downstream, you still use LQR operators for semantic shaping:

- `distinct(...)` dedupes **observed records** over windows.
- join/group windows control retention for correlation and aggregation.
- time-window GC scheduling is described in `docs/concepts/gc_and_scheduling.md`.

Rule of thumb:

- Use `LQR/ingest` when you need to control *load* and *burstiness* at the boundary.
- Use query operators (`distinct`, joins, grouping, where) to control *meaning*.
