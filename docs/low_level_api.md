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
- `joinStream`: emits `JoinResult` objects (see below) whose fields are indexed by schema name rather than positional `left`/`right`.
- `expiredStream`: emits `{ schema, key, reason, result }` packets for every eviction (schema matches the name supplied to `Schema.wrap`). Access the expired payload via `packet.result:get(packet.schema)`.

### JoinResult shape

Every emission from `joinStream` is a `JoinResult`. It behaves like a table whose keys match the schema names that participated in the match, and exposes helpers:

```lua
result:get("customers") -- returns the customer record or nil
result:schemaNames()    -- sorted list of attached schema names
result.RxMeta.schemaMap -- metadata per schema (schema name, version, joinKey, sourceTime)
```

Records are attached using the schema supplied to `Schema.wrap("schemaName", observable)`. If the same schema is used multiple times, wrap the stream with unique schema names so you can address them unambiguously.

**Record IDs:** When wrapping sources, provide an `idField` (string) or `idSelector` (function) so every record receives a stable `RxMeta.id`. Records missing the configured identifier are dropped with a warning—this keeps cache bookkeeping deterministic and allows downstream stages to trace each record back to its origin.

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
- `function(record[, side[, schemaName]]) -> key`: custom key selector. Returning `nil` drops the record with a warning. Extra parameters identify which side (`"left"/"right"`) and schema name triggered the call; they can be ignored.
- `table`: declarative per-schema configuration:

```lua
on = {
  customers = "id",
  orders = { field = "customerId" },
}
```

Each key is a schema name (matching what you passed to `Schema.wrap`). Each value accepts either a field name string, a `function(record)` callback, or a table with `field = "name"` / `selector = function(record) ... end`. Missing schema entries raise a descriptive error so misconfigurations surface early.

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
  schema = "orders",
  key = <join key>,
  reason = "evicted" | "completed" | "expired_interval" | "expired_time" | "expired_predicate" | ...,
  result = <JoinResult containing only the expired schema>,
}
```

Matched records are never expired. Unmatched records emit at most once per side: once a record expires (or the streams complete), we emit a single `{ left = record, right = nil }` or `{ left = nil, right = record }` value and remove it from the cache.

### Periodic GC (`gcIntervalSeconds`, `gcScheduleFn`)

Cache eviction normally runs when new records arrive. If you need time-based expiration to fire even when traffic stops, set `gcIntervalSeconds` to periodically sweep both caches. The join will:

- Use `gcScheduleFn(delaySeconds, fn)` if provided. This should schedule `fn` after `delaySeconds` (seconds). If it returns an object with `unsubscribe`/`dispose` **or** a plain cancel function, we will call it when the join is disposed.
- Otherwise, try to auto-detect a scheduler from `rx.scheduler.get()` that exposes `:schedule(fn, delayMs)` (e.g., `TimeoutScheduler`).
- If no scheduler is available, the join logs a warning and disables periodic GC; only opportunistic sweeps on new arrivals will run.

Tip: when hosting inside an environment with its own timer API (luv/ngx/etc), pass a thin adapter such as:

```lua
gcScheduleFn = function(delaySeconds, fn)
  local handle = myTimers.setTimeout(fn, delaySeconds * 1000)
  return function()
    myTimers.clearTimeout(handle)
  end
end
```

### Per-insert GC toggle (`gcOnInsert`)

By default the join runs retention checks on every insert (`gcOnInsert = true`). Set `gcOnInsert = false` to skip per-insert sweeps and rely on periodic GC (or opportunistic checks on completion/disposal). This reduces CPU at the cost of higher peak memory and delayed expirations/unmatched emissions between GC ticks—use only when you provide a periodic scheduler and can tolerate the latency.

## Warning & Lifecycle Hooks

Join warnings now flow through the shared logger (`log.lua`, tag `join`), so adjust `LOG_LEVEL` or use `Log.supressBelow("error", fn)` in tests to mute them temporarily.

### Observable lifecycle

- Errors from the merged stream propagate to both `joinStream` and `expiredStream`.
- Completing the merged stream flushes both caches (emitting unmatched rows and `reason = "completed"` records) and completes both observables.
- Unsubscribing from `joinStream` closes `expiredStream` (ensuring no dangling subscribers).
- To fan out a cold observable (e.g., a `JoinObservable.chain` result) without resubscribing the upstream, use `:publish():refCount()` or the sugar `:share()` to make it hot/shared. This avoids double side effects when multiple downstream subscribers need the same stream.
- `JoinObservable.chain` mappers run once per mapping per upstream `JoinResult`; mapper errors are terminal and dispose the upstream subscription. Preserve or copy `RxMeta` fields in mappers if you replace payloads.

## Behavioral Guarantees

1. **Deterministic retention:** Only records within the configured window participate in matches.
2. **Single expiration per record:** Once a record is expired, it is removed from the cache and will not fire again.
3. **Matched records never expire:** Expiration records are only emitted for unmatched records.
4. **Custom merge ordering respected:** The join processes records exactly as the merge function emits them (after validating they are tables with `side`/`record`).

## Minimum Internal Schema

Every record fed into `JoinObservable.createJoinObservable` **must** expose system metadata under `record.RxMeta`. Use `Schema.wrap("schemaName", observable, { idField = "id", schemaVersion = 2 })` (or `idSelector = function(record) ... end`) to inject/validate this metadata before wiring the join; the helper preserves existing metadata and drops records that cannot produce the configured identifier.

Mandatory/optional fields:

| Field                | Type    | Required | Description |
|----------------------|---------|----------|-------------|
| `RxMeta.schema`      | string  | ✔        | Canonical schema name, e.g. `"customers"`. |
| `RxMeta.schemaVersion` | integer | ✖        | Positive integer; `nil` means “latest”. Any zero/invalid value is normalized to `nil` with a warning. |
| `RxMeta.sourceTime`  | number  | ✖        | Event time in epoch seconds (or the unit your pipeline consistently uses). Time-based expiration prefers this value over inline `record.time`. |
| `RxMeta.id`          | any     | ✔        | Stable per-record identifier supplied by `Schema.wrap` (via `idField` or `idSelector`). |
| `RxMeta.idField`     | string  | ✔ (set by wrap) | Describes which field/selector produced `RxMeta.id`; useful for debugging. |
| `RxMeta.joinKey`     | any     | ✔ (set by join) | Populated by the join with the resolved key so downstream operators do not need to recompute it. |

Records lacking `RxMeta` (or with malformed metadata) trigger immediate errors—the join will not silently invent schemas. This keeps low-level operations deterministic and makes chained joins feasible. Downstream consumers should read payloads via `result:get("schemaName")`; higher-level adapters can still rename or merge schemas as needed.

Every schema name you pass to `Schema.wrap` becomes the label stored on the resulting `JoinResult`. Choose unique names (e.g., `"customers_seller"` vs `"customers_buyer"`) if the same physical schema appears multiple times in a chain.

### JoinResult utilities

- `result:clone()` returns a new `JoinResult` with all schema names copied. Payload tables are shallow-copied (nested tables are still shared) so mutating the new record does not affect the original.
- `Result.selectSchemas(result, { customers = "buyer" })` builds a result containing only the requested schema names (renaming them if desired).
- `result:attachFrom(otherResult, "orders", "forwardedOrders")` copies a single schema payload from another result into the current one—useful when you want to persist composite records across multiple joins.

**Note:** We shallow-copy payload tables so `record.RxMeta` can reflect the new schema name; nested structures remain references. Treat intermediate results as immutable where possible and only mutate right before emitting final sinks.

### `JoinObservable.chain`

`JoinObservable.chain(resultStream, opts)` forwards one schema from an upstream join into a new schema-tagged observable:

```lua
local enrichedOrders = JoinObservable.chain(customerOrderJoin, {
  from = {
    {
      schema = "orders",
      renameTo = "orders_with_customer",
      map = function(orderRecord, joinResult)
        local customer = joinResult:get("customers")
        if customer then
          orderRecord.customer = { id = customer.id, name = customer.name }
        end
        return orderRecord
      end,
    },
  },
})
```

- `from` (required) is either a schema name or a list of `{ schema, renameTo, map }` entries describing which schemas to forward.
- `renameTo` (optional per entry) renames the schema for the downstream join; defaults to the same name.
- `map` (optional per entry) receives the copied record and the original `JoinResult`; return a replacement table to enrich or filter emissions.

The helper subscribes lazily and unsubscribes upstream when the downstream observer disposes, so backpressure and completion semantics match vanilla Rx. The returned observable already carries `RxMeta` with the requested schema name and can be passed directly into another `JoinObservable.createJoinObservable` call.

### Determinism Policy

We intentionally **do not guarantee strict deterministic emission ordering**. The default merge streams records as soon as they arrive and cache flushes iterate via Lua tables (`pairs`), both chosen for speed and low latency. Enforcing stable global ordering would force extra buffering, sorting, and bookkeeping that would slow the low-level API. If you need deterministic ordering, supply a custom `merge` (see `examples/custom_merge_right_first.lua`) or pre-stage your streams with sequence numbers/timestamps before feeding them into `JoinObservable`.

## Examples to Build

_(These will live under `examples/` in future work.)_

- Inner join with default options, demonstrating key selector and unmatched suppression.
- Custom key selector (function) and functional `on` example.
- Interval-based expiration using event timestamps (include per-side asymmetry).
- Time schema usage with TTL, showing how expired records surface.
- Predicate-based retention enforcing domain-specific logic.
- Custom merge reordering right-stream records ahead of the left.
- Consuming `expired` stream to emit metrics/logs.

## Testing & Debugging Tips

- Use `Log.supressBelow("error", function() ... end)` to mute join warnings during noisy test sections; restore afterwards.
- The experiment scripts under `experiments/join_lua_events_*` provide runnable scenarios for retention windows and join types.
- When debugging unexpected expirations, subscribe to the `expired` stream and log both `reason` and any relevant record fields (e.g., timestamps, TTLs).
- If you see `"mergeSources must return an observable"`, ensure your custom merge returns an object with `.subscribe`.

## Known Limits / Future Work

- Only binary joins are supported; multi-way joins must chain multiple instances.
- No per-record TTL overrides; retention is configured per side.
- No built-in metrics (counts of matches/expirations) yet; consume the `expired` stream to derive your own.
- No automatic deduplication across replays; ensure upstream streams deliver each record once per desired match.
