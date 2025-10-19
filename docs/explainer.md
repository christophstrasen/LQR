## High-Level Reactive Joins vs. Classical SQL (Day 10)

This project treats every record emission flowing through a join as a **record** (a Lua table with `RxMeta` metadata). Instead of querying static tables, we observe infinite streams and compose joins declaratively using `Query`. This explainer highlights the key differences from classical SQL and maps the terminology you will see in the codebase.

### 1. Records Are Events, Not Rows

- **SQL**: rows live in tables until queried. The join runs once per statement, returning a snapshot.
- **Reactive joins**: each record carries `record.RxMeta = { schema, id, sourceTime, ... }` so downstream operators can reason about provenance. Instead of querying stored rows, we react to live record emissions passing through the join graph.
- **Implication**: order and timing matter. If the “right” side arrives before the “left” side, the join caches it until a match appears (or expires). There is no global blocking “evaluate a cartesian product” step: the result is a continuous stream of `JoinResult` objects.

### 2. Join Semantics: Match, Unmatched, Expire

Each join step produces several match statuses:

- **Matched join result** – analogous to SQL join output rows. Emitted on the main observable whenever a left/right pair satisfies the configured key.
- **Unmatched join result** – emitted on the same observable when a strategy (e.g., left join or anti join) wants to surface rows that never found a partner. This is the streaming equivalent of SQL’s “left row with NULLs”.
- **Expiration packets** – emitted on the secondary `builder:expired()` observable when a cached record leaves the retention window without a match, carrying `reason = "evicted" | "completed" | ...`. Some join strategies also emit a corresponding unmatched record emission on the main stream, so you may see the same record referenced twice (once for unmatched in the join, once on expiry).

The key distinction: the joined stream is your result—every emission there is the record as it currently stands (with or without a partner). The expiration stream simply tells you when cached rows leave the window, helping you reason about churn and whether GC/window settings are too aggressive.

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

Whenever a record leaves the retention window we emit an **expire packet** on `QueryBuilder:expired()`. Treat that stream as visibility into churn: if you see records expiring before they ever matched, consider a larger window or investing into tighter syncing of key orders in your sources.

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
