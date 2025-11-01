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

Joined stream = the results your app consumes (positive matches, plus unmatched where applicable). The expiration stream = observability about cache churn and window/GC behavior.



### 3. Observables and the Builder DSL

We compose stream joins with a fluent DSL:

```lua
local attachment = Query.from(customersObservable, "customers")
	:leftJoin(ordersObservable, "orders")
	:onSchemas({ customers = "id", orders = "customerId" })
	:window({ count = 5 })
```

- **Observables** (from Lua ReactiveX) deliver push-based streams of record emissions. They matter because they capture the *ongoing* nature of our joins: instead of preparing a data set upfront, we subscribe to each observable and react to every item it emits.
- **Builder**: `Query.from` seeds the chain with the primary observable, attaching a schema name that downstream joins reference. Each `:leftJoin` / `:innerJoin` adds another observable to the pipeline with its own label, so you can still address individual schemas in the resulting `JoinResult`.
- **Subscribers**: `attachment.query:subscribe(function(result) ... end)` is where business logic lives. It interprets every joined record emission (matched or unmatched) as soon as required sources arrive—critical for low-latency processing where waiting for a batch query would be too slow.

### 4. Windowing, Retention, and GC

Every stream is theoretically infinite, so each join must decide **how long to remember** unmatched records. The `:window` call captures this retention policy:

- **Count windows** (`{ count = N }`) keep at most `N` records per side. They offer deterministic memory bounds but can create “thrash” if your traffic spikes—new records evict older ones even if those older entries might still find matches soon.
- **Time windows** (`{ time = seconds, field = "sourceTime" }`) retain records based on timestamps. They better reflect real-world latency tolerances (“orders stick around for 30s”), but you must ensure `sourceTime` is populated and roughly synchronized.

Garbage-collection knobs (`gcOnInsert`, `gcIntervalSeconds`) decide when we actually sweep expired entries. Turning off per-insert GC improves throughput but postpones expiration packets until a periodic sweep runs. If you rely on timely “no partner” signals, keep `gcOnInsert = true` and use `gcIntervalSeconds` as a backup sweep.

Whenever a record leaves the retention window we emit an **expire packet** on `QueryBuilder:expired()`. Treat that stream as visibility into churn: if you see records expiring before they ever matched, consider a larger window or investing into tighter syncing of key orders in your sources. If you only care about “never matched,” filter by reason/`matched` when processing the packets.

### 5. Streaming joins and event counts

Joins operate on *events in a window*, not unique ids. A single emission can fan out to multiple join results if the window already contains several matching partners. Example: seven orders sit in a 3s window; one customer event with a matching `customerId` can produce up to seven join events. Re‑emitting the same id later will generate more join events as long as partners remain in the window. Header counters in the viz (`source`, `joined`, `expired`) therefore reflect event counts, not distinct ids currently visible.

### 5. Visualizing Reactive Joins

Reactive joins are inherently dynamic, but you can still visualize them. We ship a 1‑D “grid” renderer that maps record IDs. It’s ideal when your join keys live in a single numeric domain (e.g., customer IDs).

Limitations to keep in mind:

- Joins whose keys span different dimensions (e.g., customer ID ↔ order ID ↔ product SKU) cannot be perfectly embedded into one axis. When that happens the renderer uses outer borders/rectangles to mark matches that happen in these "unprojected dimensions".
- When keys drift outside the visible domain, the grid will re-center or clip. Record this metadata (window start/end) if you need reproducibility.
- Visualization is optional. The attached observables (`attachment.normalized` and `builder:expired()`) contain the full truth. Use the renderer as a sanity check, not as the source of truth.

### Checklist for Designing Reactive Joins

1. **Tag every source**: use `SchemaHelpers.subjectWithSchema` or similar helpers so `RxMeta` is present.
2. **Always call `:onSchemas`**: even if you think `onId` would work, projection/alignment logic hinges on explicit mappings.
3. **Choose a window**: count windows are simpler; time windows mirror real-world latency. Tune `gcOnInsert`/`gcIntervalSeconds` to balance freshness vs. throughput.
4. **Handle expirations**: subscribe to `builder:expired()` if unmatched/aged-out records matter to your domain.
5. **Inspect both streams**: when debugging layered joins, observe both the joined stream and the expiration stream. Match status metadata, projection metadata, and the dedup cache help you correlate how the join pipeline behaves over time.

With these concepts in mind, reactive joins become an intuitive extension of SQL thinking—just adapted to continuous, asynchronous streams rather than static tables.
