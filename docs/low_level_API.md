# JoinObservable Low-Level API

This document targets power users who want direct control over Lua ReactiveX joins. It covers the behavior of `JoinObservable.createJoinObservable`, its configuration surface, retention/expiration mechanics, and the warning/lifecycle hooks available when composing custom stream topologies.

We follow the reactive programming paradigm defined by [ReactiveX](https://reactivex.io/) and build directly on [4O4/lua-reactivex](https://github.com/4O4/lua-reactivex). If you are new to observables, subjects, or cooperative schedulers, skim those resources first—having the basics down will make the rest of this guide far easier to absorb.

## Core Concepts

Joining event streams differs from joining static tables. Streams are unbounded and may deliver records out of order or with unbounded delay, so we maintain per-key caches (one per side) to hold recent records. The `expirationWindow` defines how long a record stays “warm”; once it expires, we emit an expiration record and drop it. Only warm records can participate in matches, giving callers a predictable correctness window and preventing memory from growing unbounded. Unlike a SQL join over static snapshots, a streaming join continuously merges incoming records, emits pairs as soon as matches occur, and surfaces unmatched rows when the retention policy evicts them.

**Important:** You control how trustworthy the join is. A larger `expirationWindow` greatly improves the odds that matching records overlap in time, at the cost of more memory and CPU; a smaller window saves resources but risks expiring legitimate matches. Likewise, the better your input ordering (or custom merge), the tighter you can set the window. Pick the smallest window that still fits your typical left/right arrival gap—if a record arrives after that window closes, we simply can’t match it.

## Overview

`JoinObservable.createJoinObservable(leftStream, rightStream, options)` composes two `rx.Observable`s and emits `{ left = <record>|nil, right = <record>|nil }` pairs according to the selected join strategy. It also publishes expiration records describing when cached records age out. This low-level API is ideal when you need to embed joins inside bespoke Rx graphs, experiment with custom merge logic, or build higher-level abstractions.

- **Inputs:** any Rx observables; typically `Observable.fromLuaEvent` streams or transformed pipelines.
- **Outputs:**
  - `joinStream`: emits match/unmatched pairs according to `joinType`.
  - `expiredStream`: emits `{ side, key, record, reason }` records whenever a cached record expires (LRU, time window, predicate, manual flush).

## Constructor Reference

```lua
local joinStream, expiredStream = JoinObservable.createJoinObservable(leftStream, rightStream, options)
```

- `leftStream`, `rightStream`: Rx observables emitting tables. Each record is passed through the key selector and cached until matched or expired.
- `options`: table (documented below). Optional; defaults provide an inner join on `id` with a count-based retention window.
- Return values:
  - `joinStream`: primary observable; subscribe to get `{ left = tbl|nil, right = tbl|nil }` pairs.
  - `expiredStream`: secondary observable; subscribe to observe expiration records.

## Options

### `on`

- `string`: field name to read the join key from (default `"id"`).
- `function(record) -> key`: custom key selector. Returning `nil` drops the record with a warning.

### `joinType`

Supported join types (case-insensitive):

| Type        | Emits matched records | Emits unmatched left | Emits unmatched right |
|-------------|------------------------|----------------------|-----------------------|
| `inner`     | ✔       | ✖              | ✖               |
| `left`      | ✔       | ✔              | ✖               |
| `right`     | ✔       | ✖              | ✔               |
| `outer`     | ✔       | ✔              | ✔               |
| `anti_left` | ✖       | ✔              | ✖               |
| `anti_right`| ✖       | ✖              | ✔               |
| `anti_outer`| ✖       | ✔              | ✔               |

### `merge`

Optional function `(leftTagged, rightTagged) -> observable`. Receives the left/right streams already tagged as `{ side = "left"|"right", record = tbl }` and must return an observable. Useful for reordering, buffering, or applying custom scheduling before the merge operation commences. Failing to return an observable raises `"mergeSources must return an observable"`.

### `expirationWindow`

Defines how long each side retains records before evicting them. Only records still “warm” are eligible to match new arrivals. When a record expires, it is removed from the cache, an expiration record is published, and (if the join strategy allows) an unmatched pair is emitted.

Structure:

```lua
expirationWindow = {
  mode = "count" | "interval" | "time" | "predicate",
  -- optional per-side overrides
  left = { ... },
  right = { ... },
}
```

- If `left`/`right` are omitted, both sides inherit the top-level config. Setting `left` or `right` allows asymmetric retention policies.
- Legacy `maxCacheSize` (top-level) still applies as a default when no `expirationWindow` is set.

#### Mode: `count`

LRU eviction based on record count. This is the default mode if none is specified)
Fields:

- `maxItems`: maximum records per side (default 5).

#### Mode: `interval`

Time-based eviction driven by a field inside each record.

- `field`: name of the timestamp field (required).
- `offset`: how long (in the same units as `field`) a record stays valid.
- `currentFn`: function returning “now” (default `os.time`).
- `reason`: optional reason string (default `"expired_interval"`).

Records expire when `currentFn() - record[field] > offset`.

#### Mode: `time`

Sugar alias for `interval` that assumes records carry a `time` field and users specify a TTL.

- `ttl`: duration (seconds) after `record.time` during which the record is valid (default 60).
- Other fields (`field`, `currentFn`, `reason`) work as in `interval`.

#### Mode: `predicate`

Arbitrary retention logic controlled by user code.

- `predicate(record, side, ctx) -> boolean`: return truthy to keep the record. Errors are logged as warnings and treated as “keep”.
- `currentFn` (optional): available as `ctx.now` (defaults to `os.time`).
- `reason`: optional string (default `"expired_predicate"`).

#### Expiration records

Each record emitted via `expiredStream` has the shape:

```lua
{
  side = "left"|"right",
  key = <join key>,
  record = <original record table>,
  reason = "evicted" | "completed" | "expired_interval" | "expired_time" | "expired_predicate" | ...,
}
```

Matched records are never expired. Unmatched records emit at most once per side: once a record expires (or the streams complete), we emit a single `{ left = record, right = nil }` or `{ left = nil, right = record }` value and remove it from the cache.

## Warning & Lifecycle Hooks

### `JoinObservable.setWarningHandler(handler)`

Replaces the warning sink. Pass `nil` to restore the default stderr logger. Warnings fire when:

- Key selector returns `nil`.
- Merge emits non-table records.
- Interval fields are missing/non-numeric.
- Predicate mode throws an error.

### Observable lifecycle

- Errors from the merged stream propagate to both `joinStream` and `expiredStream`.
- Completing the merged stream flushes both caches (emitting unmatched rows and `reason = "completed"` records) and completes both observables.
- Unsubscribing from `joinStream` closes `expiredStream` (ensuring no dangling subscribers).

## Behavioral Guarantees

1. **Deterministic retention:** Only records within the configured window participate in matches.
2. **Single expiration per record:** Once a record is expired, it is removed from the cache and will not fire again.
3. **Matched records never expire:** Expiration records are only emitted for unmatched records.
4. **Custom merge ordering respected:** The join processes records exactly as the merge function emits them (after validating they are tables with `side`/`record`).

### Determinism Policy

We intentionally **do not guarantee strict deterministic emission ordering**. The default merge streams records as soon as they arrive and cache flushes iterate via Lua tables (`pairs`), both chosen for speed and low latency. Enforcing stable global ordering would force extra buffering, sorting, and bookkeeping that would slow the low-level API. If you need deterministic ordering, supply a custom `merge` (see `examples/custom_merge_right_first.lua`) or pre-stage your streams with sequence numbers/timestamps before feeding them into `JoinObservable`.

## Examples to Build

_(These will live under `examples/` in future work.)_

- Inner join with default options, demonstrating key selector and unmatched suppression.
- Custom key selector (function) and functional `on` example.
- Interval-based expiration using event timestamps (include per-side asymmetry).
- Time alias usage with TTL, showing how expired records surface.
- Predicate-based retention enforcing domain-specific logic.
- Custom merge reordering right-stream records ahead of the left.
- Consuming `expired` stream to emit metrics/logs.

## Testing & Debugging Tips

- Use `JoinObservable.setWarningHandler(function() end)` to mute warnings in unit tests; restore it afterward.
- The experiment scripts under `experiments/join_lua_events_*` provide runnable scenarios for retention windows and join types.
- When debugging unexpected expirations, subscribe to the `expired` stream and log both `reason` and any relevant record fields (e.g., timestamps, TTLs).
- If you see `"mergeSources must return an observable"`, ensure your custom merge returns an object with `.subscribe`.

## Known Limits / Future Work

- Only binary joins are supported; multi-way joins must chain multiple instances.
- No per-record TTL overrides; retention is configured per side.
- No built-in metrics (counts of matches/expirations) yet; consume the `expired` stream to derive your own.
- No automatic deduplication across replays; ensure upstream streams deliver each record once per desired match.
