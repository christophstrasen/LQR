Project: **LiQoR** – Lua integrated Query over ReactiveX  
A Lua library for expressing complex, SQL-like joins and queries over ReactiveX observable streams.

## High-Level Reactive Joins vs. Classical SQL (Day 10)

This project treats every record emission flowing through a join as a **record** (a Lua table with `RxMeta` metadata). Instead of querying static tables, we observe infinite streams and compose joins declaratively using `Query`. This explainer highlights the key differences from classical SQL and maps the terminology you will see in the codebase.

### 1. Records Are Events, Not Rows

- **SQL**: rows live in tables until queried. The join runs once per statement, returning a snapshot.
- **Reactive joins**: each record carries `record.RxMeta = { schema, id, sourceTime, ... }` so downstream operators can reason about provenance. Instead of querying stored rows, we react to live record emissions passing through the join graph.
- **Implication**: order and timing matter. If the “right” side arrives before the “left” side, the join caches it until a match appears (or expires). There is no global blocking “evaluate a cartesian product” step: the result is a continuous stream of `JoinResult` objects.

### 2. Record lifecycle and terminology

- **Source**: a source record enters the cache with its join key (logged as `input` in joins and `source` in viz).
- **Schemas**: every source is labeled (e.g., `customers`, `orders`, `refunds`) and that label lives in `RxMeta.schema` on each record. Joined records keep their schema-tagged payloads so downstream stages can chain further joins, project/rename fields, or measure latency without losing provenance.
- **Match emission**: when a left/right pair satisfies the key we consider them matched.
  **Joined record**: the `JoinResult` emitted on the main stream when a join condition is satisfied. It bundles one or more schema payloads (e.g., `customers`, `orders`). For anti joins, positive matches are not emitted at all; only the unmatched side is emitted, so no joined record appears when both sides are present.
- **Unmatched emission**: only for strategies that want it (left/outer/anti). This is separate from cache removal; it is the “no partner” result on the main joined stream.
- **Cache removal (“expired”)**: any time a cached record is removed—due to TTL/interval, count GC, predicate GC, or completion/disposal—we emit on `builder:expired()`. Packets carry `schema`, `key`, `reason` (e.g., `expired_interval | evicted | expired_predicate | completed | disposed`) and the removed record. We currently emit all removals (matched or not); if you only care about “never matched,” filter by `matched`/reason in consumers.

Joined stream = the results your app consumes (positive matches, plus unmatched where applicable). The expiration stream = observability about cache churn and join window/GC behavior.

### 3. Observables and the Builder DSL

We compose stream joins with a fluent DSL:

```lua
local attachment = Query.from(customersObservable, "customers")
    :leftJoin(ordersObservable, "orders")
    :on({ customers = "id", orders = "customerId" })
    :joinWindow({ count = 5 })
```

- **Observables** (from Lua ReactiveX) deliver push-based streams of record emissions. They matter because they capture the *ongoing* nature of our joins: instead of preparing a data set upfront, we subscribe to each observable and react to every item it emits.
- **Builder**: `Query.from` seeds the chain with the primary observable, attaching a schema name that downstream joins reference. Each `:leftJoin` / `:innerJoin` adds another observable to the pipeline with its own label, so you can still address individual schemas in the resulting `JoinResult`.
- **Subscribers**: `attachment.query:subscribe(function(result) ... end)` is where business logic lives. It interprets every joined record emission (matched or unmatched) as soon as required sources arrive—critical for low-latency processing where waiting for a batch query would be too slow.

### 3b. Per-schema distinct (pre-join dedupe)

Use `:distinct(schema, { by = "field" | fn, window = { time | count, field?, currentFn?, gcIntervalSeconds?, gcOnInsert? } })`
to drop duplicate observations for a schema before downstream operators. It runs on the current stream (even if it is already a JoinResult),
passes through other schemas untouched, and keeps at most one entry per distinct key inside the configured window. When the window expires,
a key can emit again.

### 4. WHERE-style Filtering on Joined Rows

On top of the join structure itself, the high-level API exposes a single `WHERE`-style filter:

```lua
local query =
  Query.from(customers, "customers")
    :leftJoin(orders, "orders")
    :on({ customers = "id", orders = "customerId" })
    :joinWindow({ time = 4, field = "sourceTime" })
    :where(function(row)
      local c = row.customers
      local o = row.orders -- {} when there is no matching order

      if c.type == "VIP" then
        return true
      end

      if not o.id then
        -- left-join row without a matching order
        return false
      end

      return (o.amount or 0) < (c.creditLine or math.huge)
    end)
    :selectSchemas({ "customers", "orders" })
```

Conceptually this is the reactive equivalent of `WHERE` in SQL:

- It **runs after all join steps** in the builder and **before** any `selectSchemas` projection.
- It operates on **joined rows**, not raw source events, so predicates can freely combine fields from different schemas.
- It behaves like an Rx `filter`: only rows where the predicate returns a truthy value are forwarded.

#### Row view: schema-aware but simple

Instead of passing the raw `JoinResult` into your predicate, the builder constructs a simple **row view** table:

```lua
row = {
  customers = { ... } or {}, -- absent schema → empty table
  orders    = { ... } or {},
  refunds   = { ... } or {},

  _raw_result = <JoinResult>, -- escape hatch for power users
}
```

Key rules:

- Every schema name that flows through the builder becomes a **field on the row**:
  - `row.customers` is the underlying customer record table if present in the `JoinResult`.
  - If that schema is missing (e.g. right side of a left join with no match), it is **an empty table `{}`**.
- Accessing fields is always safe:
  - `row.orders.id` simply evaluates to `nil` when there is no matching `orders` record.
  - You never need to guard with `if row.orders then …` just because of join type.
- The row view is a **plain Lua table**:
  - no metatables;
  - no magic lookups;
  - garbage-collector friendly and easy to inspect in logs or REPL.
- For advanced use cases you can still access the raw `JoinResult` through `row._raw_result` and call helpers like `:schemaNames()` or `:get("schema")` directly.

This design keeps predicates straightforward: they read like normal Lua over nested tables, while still preserving full observability and provenance when needed.

#### Where it sits in the pipeline

The logical order for the high-level API is:

1. `FROM` / root source(s) via `Query.from(...)`.
2. Zero or more join steps:
   - `:innerJoin(...)`, `:leftJoin(...)`, each with its own `on` and optional `joinWindow`.
3. **At most one** `WHERE` step:
   - `:where(function(row) ... end)` against the row view described above.
4. Optional projection:
   - `:selectSchemas({ ... })` to pick and/or rename schemas for downstream consumers.
5. Subscription and side-effects:
   - `:subscribe(...)`, `:into(...)`, visualization hooks, etc.

Two important constraints:

- Only one `where` call is allowed per builder chain. Calling it twice raises an error; this keeps the plan easy to inspect and avoids surprising combinations of predicates.
- Selection-only queries are supported. Even if you never call `innerJoin`/`leftJoin`, a `Query.from(...):where(...):selectSchemas(...)` chain still sees a row view with a single schema field (e.g. `row.customers`).

Streaming behavior remains Rx-native:

- `where` does **not** reorder or buffer emissions; it just decides which joined rows pass through.
- If the predicate throws an error, that row is dropped and a warning is logged instead of crashing the entire stream. Well-behaved predicates should be pure and side-effect free beyond logging or metrics.

### 5. Grouping and Aggregates (`GROUP BY` / `HAVING`)

Once you have a joined + filtered row stream, you often want to ask “how many of X per Y in a moving
window?” or “only let events through once their group crosses a threshold”. In SQL this is
`GROUP BY` / `HAVING`; in the high-level API we express this with `groupBy` / `groupByEnrich` /
`groupWindow` / `aggregates` / `having`.

At a high level:

- grouping runs **after joins and WHERE**, operating on the row view;
- group windows are independent of join windows (separate retention knobs);
- we support both a **group state stream** (aggregate view) and an **enriched event stream**.

#### 5.1 Aggregate view — one row per group

The aggregate view collapses many events per key into a single synthetic schema per group that keeps aggregate values up to date over a sliding window.

```lua
local grouped =
  Query.from(customers, "customers")
    :leftJoin(orders, "orders")
    :on({ customers = "id", orders = "customerId" })
    :joinWindow({ time = 7, field = "sourceTime" })
    :where(function(row)
      return row.customers.segment == "VIP"
    end)
    :groupBy("customers_grouped", function(row)
      return row.customers.id
    end)
    :groupWindow({ time = 10, field = "sourceTime" })
    :aggregates({
      row_count = true, -- exposes _count_all and per-schema _count (default)
      sum = { "customers.orders.amount" },
      avg = { "customers.orders.amount" },
    })
    :having(function(g)
      -- only keep groups where we saw at least 3 joined events
      return (g._count or 0) >= 3
    end)
```

Subscribing to `grouped` yields **one row per group key**, emitted whenever a new event enters or leaves the group window:

- `g.key` is the normalized group key.
- `g.RxMeta.groupName` is `"customers_grouped"`; `g.RxMeta.schema` is also `"customers_grouped"`, so this
  stream can be fed into further joins as a synthetic schema.
- `g._count` is the number of events in the group window.
- `g.customers.orders._sum.amount` is the sum of `row.customers.orders.amount` over the last 10
  seconds for that customer id.
- `g.customers.orders._avg.amount` is the corresponding average (nil when no samples).

Under the hood, grouping maintains a per-key window of rows and recomputes aggregates per insert.
Group windows can be:

- time-based: `{ time = seconds, field = "sourceTime", currentFn = ... }`;
- count-based: `{ count = N }` (“last N events per key”).

Group windows are **separate from join windows**; a query can use a short join window (e.g. 3s) and
a longer group window (e.g. 60s) or the other way round.

#### 5.2 Enriched event view — live group context on every row

Sometimes you want per-event decisions with group context attached, e.g. “only let a zombie event
through once at least 5 zombies have been seen in this room in the last 10 seconds”. For that we
use `groupByEnrich`, which leaves the row view intact and layers aggregates in-place:

```lua
local perEvent =
  Query.from(animals, "animals")
    :groupByEnrich("_groupBy:animals", function(row)
      return row.animals.type -- "Elephant", "Zebra", ...
    end)
    :groupWindow({ time = 10, field = "sourceTime" })
    :aggregates({
      row_count = true,
      sum = { "animals.weight" },
    })
    :having(function(row)
      -- only let animals through once at least 5 of their type
      -- have appeared in the last 10 seconds
      return (row._count or 0) >= 5
    end)
```

Each enriched row:

- is still a **row view** built from the `JoinResult`:
  - `row.animals` is the original record for that schema;
  - other schemas from earlier joins (e.g. `row.location`) remain available.
- carries group-wide metadata in `RxMeta`:
  - `RxMeta.groupKey` — the group key returned by `groupByEnrich`’s key function;
  - `RxMeta.groupName` — `"animals"` in the example above;
  - `_count` — number of events in the group window for that key.
- enriches each schema table with aggregate subtables:
  - `row.animals._sum.weight` (sum of weights for that animal type in the window);
  - `row.animals._avg.weight` if requested.
- optionally includes a **synthetic grouping schema** keyed as `"_groupBy:<groupName>"`:
  - `row["_groupBy:animals"]` contains `_count`, aggregates, and `RxMeta` with `groupKey/groupName`
    prefixes; this is useful if you want to treat grouped events as a single schema in downstream
    pipelines.

Because enriched rows preserve the original per-schema tables and only add prefixed metadata, they
fit naturally into the join mental model: you can still reason about `row.customers` / `row.orders`
as before, with extra `_sum` / `_avg` / `_min` / `_max` mirrors where you asked for aggregates.

### 5. Join Windowing, Retention, and GC

When we talk about join windowing and buffering in a streaming join, we’re really answering two questions: for how long should an event be allowed to wait for a partner, and how many events with the same key should we keep around at the same time. The **join window** answers the first question at a global level across all keys and is the dominant safety net for memory and latency, while the **per-key buffer** answers the second question at a local per-key level and lets you decide whether your join behaves like a “latest value per key” view or like a “recent history of events per key”.

#### 4.1 The match join window: how long events stay relevant

Streams are unbounded, but your process is not, so the match join window is the rule that says how long an unmatched record is allowed to stay “warm” in the cache so that late partners can still match it. A count-based join window expresses this as “how many entries can we keep before we must evict something”, whereas a time-based join window expresses it as “how old may an entry become before we consider it stale and drop it”. In both cases you are encoding a tolerance that comes from your domain, such as “orders are interesting for about 3 seconds after they arrive” or “we do not want more than 1 000 events buffered per side under any circumstances”.

- **Count join window**: `:joinWindow({ count = N })` keeps at most `N` buffered entries per side. This is the simplest option and gives you a hard, easy-to-understand memory cap, which is valuable when you mainly care that the join cannot grow without bound and are happy to let the oldest entries fall out when that cap is reached. Because eviction is based on **global insertion order**, the way a count window “slides” depends on key uniqueness and arrival patterns: a high-cardinality stream churns through many different keys, whereas a low-cardinality stream with small per-key buffers may rarely touch the global count cap.
- **Time join window**: `:joinWindow({ time = seconds, field = "sourceTime", currentFn = os.time })` keeps each entry as long as `currentFn() - entry[field] <= time`. This is the right choice when you think in terms of freshness, for example “keep customer events for 5 seconds so late orders can still match them”, and it becomes very test-friendly when you inject a fake clock so you can step time by hand instead of waiting in real time.

The builder chooses between these shapes based on the options you provide: if you specify `count`, it builds a count join window; otherwise it builds a time-based join window using `time` (or `offset`) and `field` (defaulting to `sourceTime`). If you omit `:joinWindow` entirely, we fall back to a generous default count join window so that demos do not instantly flush everything, but in real applications you should always set the join window explicitly so that your retention and memory footprint match your expectations rather than surprising you later.

Garbage-collection knobs control when the join window rules are enforced:

- `gcOnInsert` (default `true`) means “apply the join window rules every time a new event arrives”, which gives you very timely expirations and unmatched emissions but asks the CPU to do a bit of extra work on each insert.
- `gcIntervalSeconds` lets you say “also run a sweep every so often even if no new records arrive”, which is important when you use time-based join windows and want expirations to fire even in quiet periods. You should only disable `gcOnInsert` if you provide a periodic scheduler and are comfortable with expirations being delayed until the next tick.

Whenever the join window decides that an entry has overstayed its welcome—because the cache is too full or because the entry has become too old—we emit an expire packet on `QueryBuilder:expired()` with a reason like `evicted` or `expired_interval`. Watching this stream tells you whether your join window is too small (records expire before they can match) or too generous (records almost never expire), and in many debugging sessions this side channel is as important as the main joined stream itself.

#### 4.2 Per-key buffers: distinct vs. non-distinct per join key

On top of the global join window, each side of the join maintains a small **per-key buffer** (a ring) for every join key. This buffer answers the second question: how many records sharing the same key you are willing to keep at the same time, which in turn controls whether your join behaves like a “latest snapshot per key” or like a “short history of events per key”. When you set `bufferSize = 1`, you get distinct-by-key behavior where each new arrival for a key overwrites the previous one, the overwritten entry is evicted with `reason="replaced"` and sent down the expired stream, and only the newest record can ever match future partners. When you set `bufferSize > 1`, multiple arrivals per key can coexist in the buffer until the join window or the buffer itself prunes them, and each new partner can see several recent events instead of just the last one.

You configure this at the high level through `on` by using the table form for each schema, for example:

```lua
:on({
  customers = { field = "id", bufferSize = 10 },
  orders    = { field = "customerId", bufferSize = 3 },
})
```

In this configuration the customers side behaves like a short history that can hold up to ten recent customer records per id, while the orders side keeps up to three recent orders per customer id. `oneShot` is orthogonal: it controls whether a cached row is consumed after its first match, while `bufferSize`/`perKeyBufferSize` controls how many rows per key you keep warm. Combine them if you want “a handful of recent rows per key, each used once”.

On insertion the buffer first checks whether it has room for the new record; if the buffer is already full for that key, it removes the oldest entry, emits that entry with `reason="replaced"`, and then appends the new record. When a partner arrives on the other side, the join matches that partner against **all** buffered entries for the key, which means that increasing `bufferSize` increases fan-out and allows one partner event to join with several waiting records that share the same key. Conversely, decreasing `bufferSize` down to `1` forces a “latest only” behavior where only the most recent entry per key can match, which is often what you want when you are modeling state rather than individual events.

The match join window and the per-key buffer work together: the buffer prunes “horizontally” within each key, choosing between a distinct or non-distinct view of that key, while the join window prunes “vertically” across all keys, deciding how many or how old entries in total are allowed to stay warm. Because count-based join windows now count buffered entries, a large buffer per key will consume the global join window faster, so if you want “latest per key” semantics you typically set `bufferSize = 1` and pick a join window that mainly caps total growth, and if you want “every event per key” semantics you intentionally allow a larger `bufferSize` and choose a join window large enough to hold the richer history without surprising early evictions.

With these two levers in mind—join window for “how long/how many overall” and per-key buffers for “how many per key”—reactive joins become an intuitive extension of SQL thinking that happens continuously over time instead of only at query execution.

#### 4.3 What “expired” means in practice

It is important to understand what the `expired()` side channel represents and how to interpret its counts:

- **One expired record per cached entry, per join step.**  
  Every record that actually enters a join cache will be removed exactly once for that join step, and that removal produces one expired record. If you have a single join, each schema emission that reaches the join yields at most one expired record. Once you chain multiple joins (e.g., customers→orders→shipments), the same logical entity may participate in several join steps, so you can see more expired records than upstream emissions.

- **Matched vs. unmatched expirations.**  
  Expired records carry a `matched` flag:
  - `matched = false` → the record never found a partner for that join; it expired due to the join window or completion.
  - `matched = true` → the record did match at least once on that join step but is now being removed from the cache (for example, on `distinct_match` or completion). The match itself was emitted earlier on the main stream; the expiration is just the cache cleanup signal.

- **One-shot and `distinct_match`.**  
  When you mark a side as `oneShot = true` in `on(...)`, we:
  - consume a buffered entry on that side after its first match (one-and-done per row); and
  - emit an expiration with `reason = "distinct_match"` (and `matched = true`) for the consumed entry.
  That record will not be expired again later for that join step, but if the same key flows into a *second* join step (e.g., orders joining shipments), that second step has its own cache and its own `distinct_match` expirations.

- **GroupBy/HAVING expirations are separate.**  
  Grouping (`groupBy` / `groupByEnrich`) maintains its own internal windowed state and emits expirations when:
  - a group window evicts entries (e.g., time/count-based group windows), or
  - a grouped stream completes and we flush remaining entries.
  These group expirations are over *grouped rows*, not raw join inputs, and have different semantics than join-window expirations. In other words: join expirations tell you when individual source records leave the join cache; group expirations tell you when grouped aggregates or enriched rows leave the grouping window.

- **Counting expectations.**  
  Because each join step has its own cache, and grouping has its own state, you should expect:
  - up to one join-window expiration per schema emission *per join step* that the emission participates in; plus
  - additional expirations from distinct (`distinct_match`) and from grouping windows.  
  This means that the total number of expired records across all origins (`join`/`distinct`/`group`) can legitimately exceed the number of upstream emissions once you have multi-step joins or grouping in play.

In practice, treating `expired()` as an observability stream (“what left which cache, when, and why”) rather than as a strict “one-to-one mirror of upstream” makes it easier to reason about behavior: you can filter by `origin` (`join` vs `distinct` vs `group`), by `matched` flag, or by `reason` to answer questions like “which events never matched?”, “how often do distinct matches happen per key?”, or “how aggressively is my group window evicting aggregates?” without changing your main join logic.

### 6. Streaming joins and event counts

Joins operate on *events in a join window*, not unique ids. A single emission can fan out to multiple join results if the join window already contains several matching partners. Example: seven orders sit in a 3s join window; one customer event with a matching `customerId` can produce up to seven join events. Re‑emitting the same id later will generate more join events as long as partners remain in the join window. Header counters in the viz (`source`, `joined`, `expired`) therefore reflect event counts, not distinct ids currently visible.

### 7. Visualizing Reactive Joins

Reactive joins are inherently dynamic, but you can still visualize them. We ship a 1‑D “grid” renderer that maps record IDs. It’s ideal when your join keys live in a single numeric domain (e.g., customer IDs).

Limitations to keep in mind:

- Joins whose keys span different dimensions (e.g., customer ID ↔ order ID ↔ product SKU) cannot be perfectly embedded into one axis. When that happens the renderer uses outer borders/rectangles to mark matches that happen in these "unprojected dimensions".
- When keys drift outside the visible domain, the grid will re-center or clip. Record this metadata (window start/end) if you need reproducibility.
- Visualization is optional. The attached observables (`attachment.normalized` and `builder:expired()`) contain the full truth. Use the renderer as a sanity check, not as the source of truth.

### Checklist for Designing Reactive Joins

1. **Tag every source**: use `SchemaHelpers.subjectWithSchema` or similar helpers so `RxMeta` is present.
2. **Always call `:on`**: explicit mappings keep projection/alignment and observability accurate.
3. **Choose a join window**: count-based join windows are simpler; time-based join windows mirror real-world latency. Tune `gcOnInsert`/`gcIntervalSeconds` to balance freshness vs. throughput.
4. **Handle expirations**: subscribe to `builder:expired()` if unmatched/aged-out records matter to your domain.
5. **Inspect both streams**: when debugging layered joins, observe both the joined stream and the expiration stream. Match status metadata, projection metadata, and the dedup cache help you correlate how the join pipeline behaves over time.
