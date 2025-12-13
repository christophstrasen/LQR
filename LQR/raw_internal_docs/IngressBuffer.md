# IngressBuffer briefing

This document sketches a common architecture we keep running into when integrating LQR/reactivex with “tick-driven” runtimes (e.g. Project Zomboid): event sources can be bursty, downstream processing is non-trivial, and there is no end-to-end backpressure protocol.

The core idea is to separate *event arrival* from *work execution* by inserting an explicit buffering layer between them that works in 3 stages: Ingest → Buffer → Drain.

Decision: this layer is intentionally **pre-schema** (before `Schema.wrap(...)`) and should remain mostly LQR-agnostic plumbing. We ship it with LQR for support/versioning, but keep it loosely coupled so it can be replaced later without changing query semantics.

In practice, it is fine for this module to depend on LQR utilities such as `LQR/util/log` for warnings; “LQR-agnostic” here means “not tied to query semantics”.

---

## 1. Problem statement

In many Lua game runtimes:

- “Upstream” sources (engine events, custom events, polls/probes) can produce bursts (e.g. `LoadGridsquare` may fire for many squares at once).
- Downstream work (schema wrapping, joins, filtering, user callbacks) is not free and often scales with input volume.
- Classic backpressure (“downstream asks for N”) is not available:
  - event producers cannot be slowed down or paused; and
  - lua-reactivex/LQR operators don’t implement a reactive-streams request protocol.

If we process events immediately in the event handler, we risk hitching (long frames), runaway CPU usage, and unbounded memory growth.

---

## 2. The concept

We model any fact/event/probe as a three-stage pipeline:

1. **Ingest**  
   Runs at event arrival time. Must be *cheap*. Captures only what is needed to do work later (often an id/coords, plus a timestamp).

2. **Buffer**  
   Holds “pending work” using a bounded data structure. Applies an explicit overflow/compaction strategy when volume exceeds capacity.

3. **Drain**  
   Runs under a scheduler on a regular cadence (typically “each tick”). Uses a fixed budget (items per tick and/or millis per tick) to pop buffered work, materialize records, and push them into downstream observables.

This gives us a single place to enforce performance constraints while keeping event handlers lightweight and predictable.

---

## 3. Goals and non-goals

### Goals

- Keep event handlers and “hot” hooks minimal and bounded.
- Make overload behavior explicit and testable (no silent drops).
- Support common compaction semantics (dedupe/set, latest-by-key, bounded queue).
- Provide basic metrics to diagnose overload and tune budgets.
- Stay host-agnostic: the buffering/draining primitive should not assume a specific engine API.

### Non-goals

- Implementing a full reactive-streams backpressure protocol inside LQR.
- Making policy decisions for a domain: what constitutes an id, what dropping means, what is safe to compact.
- Hiding cost of downstream subscriber logic. User callbacks remain “opaque work” and may require their own shaping.

---

## 4. Responsibilities: LQR vs. domain/user

### LQR responsibilities (mechanism)

- Provide a small, well-tested ingest/buffer/drain primitive:
  - buffering data structures;
  - explicit overflow/compaction strategies;
  - deterministic drain behavior under budget;
  - lightweight metrics; and
  - predictable semantics (ordering, replacement rules, drop/replacement accounting).
- Provide integration hooks that allow a host (or library) to call `drain(...)` on a cadence.
- Provide observability surfaces (describe/metrics) without forcing logging.

### Domain/user responsibilities (policy)

- Define *what is a work item* and what is the *key* (e.g. `squareId`, `roomId`, `(x,y,z)`).
- Choose a buffering policy and capacity appropriate to semantics:
  - “state coverage” sources usually want `dedupSet` or `latestByKey`;
  - “event history” sources may require a bounded FIFO queue.
- Decide what happens on overflow (drop newest/oldest, compact, or “fail + log”).
- Provide a drain-time “materializer”: a function that turns a lightweight buffered item (often just a key like `{ squareId = ... }`) into the full record that will be emitted downstream.
- Choose and tune budgets (per tick, per type, and optionally per source class).

---

## 5. Buffering and compaction strategies

We expect to support a small set of strategies that cover most use cases:

These modes are configured per buffer. When lanes are enabled, the buffer may maintain per-lane internal storage as needed (in v1, `queue` is explicitly per lane).

Rule: `capacity` counts different things by mode:
- `dedupSet` / `latestByKey`: number of unique keys currently pending.
- `queue`: number of queued items (per lane queues still count toward one global capacity).

### 5.1 `dedupSet` (unique pending keys)

- Buffer contains keys only once (“pending set”).
- Ingesting the same key again is a no-op (or updates metadata like `lastSeen`).
- Ideal for bursty “refresh/coverage” signals (e.g. “square loaded”, “entity changed”).
- Capacity behavior (v1): when at capacity and a new key arrives, evict from the lowest-priority lane; within that lane, evict the key with the oldest `lastSeen` (LRU-ish).
  - `lastSeen` should be tracked via a monotonic `ingestSeq` counter (not wall-clock), so this policy works even when no reliable clock exists.

### 5.2 `latestByKey` (compaction map)

- Buffer keeps exactly one item per key, replacing older payloads.
- Ideal for “current state” signals where only the latest value matters per key (e.g. status/health/mode updates), especially when updates can arrive in bursts.
- Capacity behavior (v1): when at capacity and a new key arrives, evict from the lowest-priority lane; within that lane, evict the key with the oldest `lastSeen` (LRU-ish).
  - `lastSeen` should be tracked via a monotonic `ingestSeq` counter (not wall-clock), so this policy works even when no reliable clock exists.

### 5.3 `queue` (bounded FIFO)

- Buffer preserves event order (within a single queue).
- Requires an explicit overflow policy (drop oldest/newest, drop buffer, or “fail”).
- Ideal when history matters (rare for world-state observation, common for “player actions” streams).
- Default overflow policy (v1): `dropOldest`.
  - Decision (v1): queues are per lane (each lane maintains its own FIFO), which keeps strict-priority draining simple and extensible.
  - Explicit overflow rule: on overflow, pick the losing lane (lowest priority; RR on ties), then `dropOldest` within that lane’s FIFO.

### V1 stance: no cooldowns / time windows

Ingress is meant to be admission control: bounded memory + budgeted drain, with a small number of knobs.
In v1 we intentionally avoid time-window/cooldown semantics in ingress to keep it host-friendly (no clock/tick coupling) and to avoid adding another semantic dimension beyond lanes.

Instead, v1 relies on:

- pending-only compaction (`dedupSet` / `latestByKey`);
- explicit budgets (`maxItems`, optional `maxMillis`);
- lane priorities; and
- LRU-ish eviction by `ingestSeq` when at capacity.

If a domain needs semantic time shaping (“only once per N seconds”), that should be expressed downstream via LQR operators/helpers after items are admitted.
We revisit a first-class `cooldownTicks` only if we see hot-key churn where keys are drained and immediately re-enqueued repeatedly despite dedupe and budgets.

---

## 6. Budget model (host-friendly, LQR-generic)

The drain loop needs a budget model that:

- maps directly to tick-driven engines; and
- can still be expressed in a generic way.

Recommended budget shapes:

- **Items budget:** `maxItems` (always available, deterministic).
- **Time budget (optional):** `maxMillis` (only if a reliable clock is available in the host).
  - When time budgeting is enabled, the host provides the clock (e.g. `nowMillis = function() ... end`).
  - If no clock is provided, `maxMillis` is ignored and the item budget remains the limiter.
  - If `nowMillis()` does not return a number, is non-monotonic during the drain call (time goes backwards), or `maxMillis <= 0`, drain 0 items for that tick and warn.

Note: `maxMillis` is about limiting *CPU time spent per drain call*. It is independent from `ingestSeq`:
`ingestSeq` is a monotonic internal counter used for eviction/age metrics even in hosts without a reliable clock.

Drain should return stats so callers can adapt:

- how many items were processed;
- how many remain pending;
- whether any drops/replacements happened; and
- optional “spentMillis” when timing is enabled.

### 6.1 Drain stats semantics (proposal)

To keep the v1 surface small, `drain(...)` returns a minimal stats table:

- `processed`: number of items whose `handle(item)` was invoked.
- `pending`: number of pending items *after* the drain (i.e. `pendingAfter`).
- `dropped`: number of drop events *since the previous `drain(...)` call* (includes overflow evictions and `badKey` drops that occurred during `ingest(...)` in between drains).
- `replaced`: number of replacement events *since the previous `drain(...)` call* (for `latestByKey`, where a new item for an existing key replaces the buffered payload).
- `spentMillis`: optional; only set when a usable `nowMillis` clock is provided and is monotonic for the duration of the drain call.

These drain deltas are for immediate feedback and are intentionally independent from the metrics contract.
Totals since the last `metrics_reset()` are exposed via `buffer:metrics_get()` (e.g. `droppedTotal`, `replacedTotal`).

---

## 7. Bias, priority, and fairness

Many domains want “bias” without an explosion of knobs.

We want LQR to support a single generic dimension for “bias”: **lanes**.

- A **lane** is a domain-defined label (string) attached to each buffered item (e.g. `"combat.urgent"`, `"world.refresh"`, `"probe.background"`).
- Lanes are intentionally *not* limited to “source” (engine event vs probe). A Zomboid mod may want to prioritize an engine event because it represents a critical domain moment (e.g. “zombie killed”), while still draining other work eventually.

Suggested model (small surface, widely applicable):

- The domain provides a cheap `lane(item)` classifier at ingest time.
  - Example: `ZombieKilled` → `"combat.urgent"`, `LoadGridsquare` → `"world.refresh"`.
- The scheduler drains lanes under a per-tick budget using:
  - **strict priority** (drain higher priority lanes first);
  - (future) **weighted fairness** (weighted round-robin across lanes to avoid starvation); and
  - (future) **minimum reservations** (ensure a lane gets at least N items per tick if pending).
- Apply budgets per *type/schema* first (e.g. squares vs zombies), then allocate within that type by lane.

Decision: start with strict priority + leftover budget. Add fairness/reservations only after concrete starvation reports.

Decision (v1): lane bias is expressed via per-lane `priority` only; `maxItemsPerTick` is global across lanes (no per-lane caps yet).

---

## 8. Integration patterns (examples)

### 8.1 Tick-driven engines

- Event handler calls `ingest(...)`.
- `OnTick` (or equivalent) calls `drain({ maxItems = N })`.

### 8.2 Starlit TaskManager (optional)

TaskManager can host the drain loop as a task:

- A task runs each tick and calls `drain(...)`.
- Coroutines can implement long-running probes naturally by yielding each tick.

The buffering/draining primitive still owns overload semantics; TaskManager is only a scheduler backend.

### 8.3 Headless/tests

- Tests can ingest synthetic items and call `drain(...)` manually in a loop.
- This makes overload semantics and drop behavior easy to validate without engine dependencies.

---

## 9. Observability and debugging

IngressBuffer should expose enough introspection to answer:

- “Why am I lagging?” → pending depth, drops, drain throughput.
- “What am I missing?” → drop counts by policy, replacement counts by key.
- “How bursty is this?” → peak pending, average drain, per-tick processed.

Suggested metric counters:

- `ingestedTotal`, `enqueuedTotal`, `dedupedTotal`
- `drainedTotal`, `droppedTotal`, `replacedTotal`
- `pending`, `peakPending`

Logging should remain opt-in; callers can wire their own logger to onDrop/onReplace hooks.

Decision: overflow should not emit additional streams/events by default. Drops/replacements should be observable via:
- returned drain stats and/or pullable metrics; and
- optional hooks (`onDrop`, `onReplace`) for domains that want logging or counters.
“Explicit” in this context means “counted + observable via metrics (and optionally hooks)”.

Decision: per-lane stats should be exposed via a pull-based `buffer:metrics_get()` snapshot (and/or `scheduler:metrics_get()`), not necessarily attached to every `drain(...)` return.

---

## 10. Envisioned API / knobs (draft)

The names below are illustrative; the key is the surface area.

### 10.1 Single buffer/drainer

```lua
local Ingest = require("LQR/ingest")

local buffer = Ingest.buffer({
  name = "squares.load",            -- for metrics/debug
  mode = "dedupSet",                -- "dedupSet" | "latestByKey" | "queue"
  ordering = "none",                -- "none" | "fifo" (optional; affects drain order for non-queue modes; ignored for queue)
  capacity = 5000,                  -- required: max unique keys or max queued items (no default)
  key = function(item) return item.squareId end,
  -- Optional: classify items into domain-defined scheduling lanes.
  -- If omitted (or if lane(...) returns nil), the lane defaults to "default".
  -- Domains can later add this incrementally to prioritize specific items
  -- (e.g. an engine event representing "ZombieKilled" → "combat.urgent").
  lane = function(item)
    if item and item.kind == "ZombieKilled" then
      return "combat.urgent"
    end
    return nil
  end,
  -- Lane priorities (v1):
  -- Higher number = higher priority. Priorities start at 1 ("default" should be 1).
  -- Unknown lanes default to priority 1.
  lanePriority = function(laneName)
    if laneName == "combat.urgent" then
      return 3
    end
    return 1
  end,

  onDrainStart = function(info) end, -- optional hook: { nowMillis, maxItems, maxMillis }
  onDrainEnd = function(info) end,   -- optional hook: { processed, pending, dropped, replaced, spentMillis }
  onDrop = function(info) end,       -- optional hook: { reason, item, key, lane }
  onReplace = function(info) end,    -- optional hook: { old, new, key, lane }
})

buffer:ingest({ squareId = 123, kind = "LoadGridsquare", observedAt = 456 })

local stats = buffer:drain({
  maxItems = 200,
  maxMillis = nil,                  -- optional
  nowMillis = nil,                  -- optional; required for maxMillis (must behave monotonically during drain)

  handle = function(item)
    -- “materialize” or “emit” work; domain code decides what this does.
  end,
})

-- Pull metrics snapshot (including per-lane counters when enabled).
local metrics = buffer:metrics_get()

-- Optional: reset counters/peaks (keeps config/buffer contents intact).
buffer:metrics_reset()
```

### 10.2 Multi-buffer scheduler helper (optional)

```lua
local sched = Ingest.scheduler({
  name = "facts.squares",
  maxItemsPerTick = 200,
  -- v1: priorities only (weights/reservations are future)
  -- Note: scheduler priority decides between buffers; lane priority decides within a buffer.
})

sched:addBuffer(buffer, { priority = 10 })
sched:addBuffer(otherBuffer, { priority = 5 })

-- host tick:
sched:drainTick(function(item) ... end)

-- Pull metrics snapshot for the scheduler and its child buffers.
local schedMetrics = sched:metrics_get()

-- Optional: reset counters/peaks for the scheduler and all child buffers.
sched:metrics_reset()
```

### 10.3 Knobs we expect to need

- Buffer mode: `dedupSet | latestByKey | queue`
- Capacity and overflow policy (for queue-like modes)
- Key selector
- Optional cooldown (`cooldownTicks`) to reduce churn (future; not in v1)
- Budget: `maxItems` (+ optional `maxMillis`)
- Lanes with strict priorities (v1); weights/reservations (future)
- Metrics: on/off, or “pull metrics snapshot”

---

## 11. Decisions (current)

- **Module placement:** `require("LQR/ingest")`.
- **Scope:** ship a single-buffer primitive and an optional multi-buffer scheduler helper.
- **Capacity:** required and explicitly chosen by the domain (no implicit defaults).
- **Capacity + lanes (v1):** capacity is enforced globally across all lanes. On overflow, the lowest-priority lane loses; if multiple lanes share the same lowest priority, eviction rotates round-robin between them deterministically.
- **Overflow policy (v1):**
  - `queue`: default overflow policy is `dropOldest`.
  - `dedupSet` / `latestByKey`: when at capacity, evict from the losing lane; within that lane, evict the key with the oldest `lastSeen` (LRU-ish).
  - `lastSeen` is tracked using a monotonic `ingestSeq` and updates on every ingest attempt for a key (including when the key is already pending), so eviction is based on “least recently seen”.
  - `key(item) == nil` is treated as a bug in the caller: drop the item, `Log.warn(...)`, and invoke `onDrop({ reason = "badKey", ... })` when configured.
- **Lane changes for pending keys (v1):** if the same key is ingested again while already pending and its `lane(item)` classification differs, we migrate the key to the new lane for clarity (edge case; avoids split-brain behavior between “stored lane” and “priority lane”).
- **Ordering:**
  - `dedupSet` / `latestByKey`: no ordering guarantees by default.
  - `ordering = "fifo"` is a first-class knob for domains that prefer spending memory to reduce per-tick bookkeeping and keep related work closer together.
  - Decision (v1): for `dedupSet` / `latestByKey`, `ordering = "fifo"` means FIFO by **first enqueue time** *within each lane* (oldest pending first). Re-ingesting an already-pending key updates `lastSeen` for eviction decisions but does not move its position in the FIFO order.
  - `queue` is already FIFO; `ordering` is ignored for `queue` (warn on every drain to highlight misconfiguration).
- **Drain return shape (v1):** minimal stats `{ processed, pending, dropped, replaced }`.
  - `dropped`/`replaced` are deltas since the previous drain; totals are in `:metrics_get()`.
  - Per-lane stats are available via pull-based `:metrics_get()` snapshots, not necessarily attached to every drain return.
- **Scheduler (v1):** lanes have `priority`; scheduler has a single global `maxItemsPerTick` budget shared across lanes (no per-lane caps in v1).
- **Hooks (v1):** support `onDrainStart`, `onDrainEnd`, `onDrop`, `onReplace`.
- **Time budgets:** optional; enabled only when the host supplies a clock (`nowMillis`).
  - If `maxMillis` is misconfigured (`<= 0`) or `nowMillis()` is not a number, drain 0 items for that tick and warn.
- **Cooldown/time windows:** not part of v1; revisit only if we observe hot-key churn that pending-dedupe cannot tame.
- **Overflow surfacing:** no extra streams by default; use stats/metrics + optional hooks (`onDrop`, `onReplace`).
- **Fairness:** v1 uses strict priority + leftover budget; fairness/weights/reservations are future extensions.
- **Division of labor:** ingress is pre-schema and mostly LQR-agnostic and owns pacing/overload; LQR operators own semantic shaping after records are admitted.

---

## 12. Metrics contract (v1)

IngressBuffer metrics are meant to be cheap to maintain and cheap to read.

- `buffer:metrics_get()` returns a plain Lua table.
- `buffer:metrics_reset()` resets only the metrics (counters/peaks/averages); it does **not** clear buffered items.

Recommended fields (v1):

- Identity/config: `name`, `mode`, `capacity`, `ordering`.
- Sequence/age (based on monotonic `ingestSeq`):
  - `ingestSeqNow`
  - `oldestSeq`, `newestSeq`, `seqSpan` (nil/0 when empty as appropriate)
- Depth:
  - `pending`, `peakPending`
- Totals:
  - `ingestedTotal`, `enqueuedTotal`, `dedupedTotal`, `replacedTotal`, `droppedTotal`, `drainedTotal`, `drainCallsTotal`
  - `droppedByReason` (small map, e.g. `badKey`, `overflow`, `evictLRU`, `dropOldest`)
  - Definition: `enqueuedTotal` counts only newly admitted keys/items (first time a key enters the buffer). `replacedTotal` counts replacements for existing keys and does not increment `enqueuedTotal`.
- Last drain snapshot:
  - `lastDrain = { processed, pendingAfter, dropped, replaced, spentMillis }` (`dropped`/`replaced` are deltas; `spentMillis` optional; see drain semantics)
- Averages (since last reset; no percentiles in v1):
  - Running mean: `avgPending`, `avgSeqSpan`
  - EMA (optional): `emaPending`, `emaSeqSpan` (for a “recent trend” view; alpha fixed in code)
- Per-lane summary (when lanes are used):
  - `lanes[laneName] = { pending, peakPending, drainedTotal, droppedTotal, seqSpan }`

Scheduler metrics mirror the same style via `scheduler:metrics_get()` / `scheduler:metrics_reset()`, with per-buffer breakdowns under `buffers[name] = ...`.

Note: `metrics_reset()` does not affect ingestion/drain behavior (buffer contents, ordering, lane queues, round-robin pointers). It only resets counters/peaks/averages that are surfaced for observability.
