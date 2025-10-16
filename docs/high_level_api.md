# High-Level Join API (Draft)

This captures the intended fluent API for our Lua-ReactiveX join layer. It assumes every
incoming record is schema-tagged via `Schema.wrap` and focuses on being declarative, chainable,
and Rx-native.

## Baseline
- Every record carries `record.RxMeta = { schema = "<name>", id = <stable>, schemaVersion?,
  sourceTime? }`.
- IDs are unique **per schema**. `onId()` uses `RxMeta.id` scoped to each schema; it is not a
  cross-schema key.
- Key selection never requires inline lambdas. If a required field is missing for a schema, the
  API raises a clear configuration error.

## Core verbs
- `Query.from(sourceObservable)` → returns a JoinObservable-bound query (schema-aware).
- `:innerJoin(other)` / `:leftJoin(other)` → chain more sources (raw observables or join outputs).
- `:onField("fieldName")` → use the same field name for all schemas currently in play.
- `:onId()` → use `RxMeta.id` for all schemas.
- `:onSchemas{ schemaA = "id", schemaB = "orderId", ... }` → explicit map for differing names.
- `:window{ time=seconds | count=n, field="sourceTime", currentFn=os.time, gcIntervalSeconds? }`
  → retention/expiration policy.
- `:selectSchemas{ "customers", "orders", ... }` → project/rename schemas for downstream clarity.
- `:describe()` → returns a stable plan (table/string) for tests and debugging.
- Rx-native ops (`filter`, `map`, `merge`, `throttle`, etc.) remain available on the underlying
  observable.

### Selection-only queries
- The builder works even without additional `innerJoin/leftJoin` calls. You can `Query.from(source)`
  and immediately `selectSchemas` (or apply Rx operators) to treat it as a simple projection/query
  with schema awareness. Future non-join queries can live on the same surface without changing the
  mental model.

## Chaining without manual fan-out
- Join verbs accept either raw schema-tagged observables **or** JoinResult observables directly.
- Internally we auto-fan-out the schemas referenced by the key selector and selection step, so users
  never call a separate `chain` helper. Schema names in `onField/onSchemas/selectSchemas` make data
  flow explicit.

## Example flow
```lua
local joined =
  Query.from(customers)                   -- schema "customers"
    :leftJoin(orders)                     -- schema "orders"
    :onField("customerId")                -- same field name across both schemas
    :window{ time = 4, field = "sourceTime" }
    :innerJoin(refunds)                   -- schema "refunds"
    :onSchemas{ orders = "id", refunds = "orderId" } -- differing field names
    :selectSchemas{ "customers", "orders", "refunds" }

local plan = joined:describe()            -- stable summary for tests/debugging
local subscription = joined:subscribe(...) -- standard Rx subscription
```

## `onId()` mechanics
- `onId()` reads `record.RxMeta.id` per schema and uses that as the join key. It never expects
  cross-schema uniqueness; IDs are scoped by schema name.
- When to use:
  - Your sources were wrapped with `Schema.wrap(..., idField = "<field>")` and that same stable id
    is the intended join key across participating schemas.
  - You want joins to survive payload reshaping/renaming as long as metadata stays intact.
  - You prefer a terse form when the key already lives in metadata for all schemas involved.
- When to prefer `onSchemas{...}`:
  - Field names differ across schemas (`customerId` vs `id`).
  - You want explicit mappings and clearer intent in tests/docs.
- If any schema is missing `RxMeta.id`, the API raises a configuration error rather than silently
  degrading.

## Expiration, unmatched, and expired records
- Retention windows (time/count/etc.) evict records; evictions emit on an `expired` side channel with
  `{ schema, key, reason, result }`.
- Join strategies may also emit an unmatched projection (a JoinResult containing the remaining
  schema(s)) when an entry expires or arrives without a partner, depending on join type and policy.
- “Expired record” = eviction event. “Unmatched JoinResult” = projection emitted due to join policy
  (often triggered by expiration). Not the same as “never seen.”

## Implementation plan (draft)
- **Query facade surface**
  - Implement `Query.from/innerJoin/leftJoin/onField/onId/onSchemas/window/selectSchemas/describe/into`
    as a thin layer over existing join internals.
  - `onField`/`onId`/`onSchemas` resolve to a normalized key map per schema; missing fields at
    runtime emit warnings (not hard errors). `onSchemas` coverage gaps are config errors up front.
- **Schema enforcement**
  - Keep `Schema.wrap` (or equivalent) mandatory so every record has `RxMeta.schema/id/...`. Emit a
    clear warning if `id` is missing at runtime.
- **Auto-chaining**
  - Allow join inputs to be raw observables or JoinResult streams; internally fan out requested
    schemas via `JoinObservable.chain` (or equivalent) so no user-facing chain call is needed.
- **Windows**
  - `window{ time | count, field?, currentFn?, gcIntervalSeconds?, gcOnInsert? }`. No window means
    no expiration. Default: a large count window (e.g., `{ count = 1000 }`) to keep behavior simple
    when unspecified.
- **Select/rename**
  - `selectSchemas` to shape downstream schema names; required for readability.
- **Describe**
  - `describe()` returns a function-free Lua table; optional `describeAsString()` for logs. Make it
    stable for snapshot tests.
- **into**
  - `into(tbl)` appends each emission (`tbl[#tbl+1] = emission`) and returns the observable for
    further chaining or subscribe.
- **Scheduler**
  - Global default scheduler; allow test override (e.g., `Query.setScheduler(testSched)` or per-query
    override) so expiration tests can use a synthetic clock.
- **Error handling**
  - Warn-and-continue on selector field misses; rely on underlying Rx for pcall-wrapping subscribe
    callbacks. Avoid extra wrapping here until predicates are introduced.
- **Tests**
  - Selector validation: `onField` missing field warns; `onSchemas` missing coverage errors.
  - Auto-chaining with JoinResult inputs.
  - Window/expiration behavior (time/count) with injected clock/scheduler.
  - `describe` stability (table shape) and `into` append behavior.
