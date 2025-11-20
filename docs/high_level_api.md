Maybe outdated???

# High-Level Join API (Draft)

This captures the intended fluent API for our Lua-ReactiveX join layer. It assumes every
incoming record is schema-tagged via `Schema.wrap` and focuses on being declarative, chainable,
and Rx-native.

## Baseline
- Every record carries `record.RxMeta = { schema = "<name>", id = <stable>, schemaVersion?,
  sourceTime? }`.
- Key selection never requires inline lambdas. If a required field is missing for a schema, the API
  raises a clear configuration error.

## Core verbs
- `Query.from(sourceObservable)` → returns a JoinObservable-bound query (schema-aware).
- Joins: `:innerJoin(other)` / `:leftJoin(other)` / `:rightJoin(other)` / `:outerJoin(other)` /
  `:antiLeftJoin(other)` / `:antiRightJoin(other)` / `:antiOuterJoin(other)` → chain more
  sources (raw observables or join outputs).
- `:onSchemas{ schemaA = "id", schemaB = "orderId", ... }` → explicit map for join keys. Required.
- `:joinWindow{ time=seconds | count=n, field="sourceTime", currentFn=os.time, gcIntervalSeconds? }`
  → join window/retention/expiration policy for the most recent join. Use `:withDefaultJoinWindow{...}`
  (or `Query.setDefaultJoinWindow{...}` globally) to set the fallback applied when a join omits
  `:joinWindow`.
- `:selectSchemas{ "customers", "orders", ... }` → project/rename schemas for downstream clarity.
- `:describe()` → returns a stable plan (table/string) for tests and debugging.
- Rx-native ops (`filter`, `map`, `merge`, `throttle`, etc.) remain available on the underlying
  observable.

## Builder lifecycle & activation
- Builders are immutable configs. Every fluent call returns a new `QueryBuilder`; the original is unchanged, even if it is already active.
- A builder becomes active only when you **consume** it: `subscribe(...)`, `into(bucket)`, `expired()`, or when it is passed as a source into another `Query` (sub-query builds it). The first activation emits an info log.
- Once active, its configuration is frozen. Any further `:where/:groupBy/:selectSchemas/:innerJoin/...` on that same builder creates a **new** query; existing subscriptions are unaffected and keep running.
- Assemble the full query before consuming it. Chaining more steps after consumption creates a new pipeline (a runtime split) and can multiply load if both run.
- Sub-queries: passing a builder into `innerJoin/leftJoin` builds it and reuses that output; it never reconfigures the original. Passing a raw observable simply adds another subscriber.

### Selection-only queries
- The builder works even without additional `innerJoin/leftJoin` calls. You can `Query.from(source)`
  and immediately `selectSchemas` (or apply Rx operators) to treat it as a simple projection/query
  with schema awareness. Future non-join queries can live on the same surface without changing the
  mental model.

## Chaining without manual fan-out
- Join verbs accept either raw schema-tagged observables **or** JoinResult observables directly.
- Internally we auto-fan-out the schemas referenced by the key selector and selection step, so users
  never call a separate `chain` helper. Schema names in `onSchemas/selectSchemas` make data
  flow explicit.

## Example flow
```lua
local joined =
  Query.from(customers)                   -- schema "customers"
    :leftJoin(orders)                     -- schema "orders"
    :onSchemas{ customers = "id", orders = "customerId" }
    :joinWindow{ time = 4, field = "sourceTime" }
    :innerJoin(refunds)                   -- schema "refunds"
    :onSchemas{ orders = "id", refunds = "orderId" }
    :selectSchemas{ "customers", "orders", "refunds" }

local plan = joined:describe()            -- stable summary for tests/debugging
local subscription = joined:subscribe(...) -- standard Rx subscription
```

## Expiration, unmatched, and expired records
- Retention join windows (time/count/etc.) evict records; evictions emit on an `expired` side channel with
  `{ schema, key, reason, result }`.
- Join strategies may also emit an unmatched projection (a JoinResult containing the remaining
  schema(s)) when an entry expires or arrives without a partner, depending on join type and policy.
- “Expired record” = eviction event. “Unmatched JoinResult” = projection emitted due to join policy
  (often triggered by expiration). Not the same as “never seen.”

## Implementation plan (draft)
- **Query facade surface**
  - Implement `Query.from/innerJoin/leftJoin/onSchemas/joinWindow/selectSchemas/describe/into` as a thin
    layer over existing join internals.
  - `onSchemas` resolves to a normalized key map per schema; missing fields at runtime emit warnings
    (not hard errors). `onSchemas` coverage gaps are config errors up front.
- **Schema enforcement**
  - Keep `Schema.wrap` (or equivalent) mandatory so every record has `RxMeta.schema/id/...`. Emit a
    clear warning if `id` is missing at runtime.
- **Auto-chaining**
  - Allow join inputs to be raw observables or JoinResult streams; internally fan out requested
    schemas via `JoinObservable.chain` (or equivalent) so no user-facing chain call is needed.
- **Join windows**
  - `joinWindow{ time | count, field?, currentFn?, gcIntervalSeconds?, gcOnInsert? }`. No join window on a
    step means “use the default join window.” Default fallback: a large count-based join window (e.g.,
    `{ count = 1000 }`) to keep behavior simple when unspecified. A per-query default can be set with
    `withDefaultJoinWindow`, and a process-wide default with `Query.setDefaultJoinWindow`.
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
  - Selector validation: `onSchemas` missing coverage errors.
  - Auto-chaining with JoinResult inputs.
  - Join window/expiration behavior (time/count) with injected clock/scheduler.
  - `describe` stability (table shape) and `into` append behavior.
