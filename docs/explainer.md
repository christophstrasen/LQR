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

When we talk about windowing and buffering in a streaming join, we’re really answering two questions: for how long should an event be allowed to wait for a partner, and how many events with the same key should we keep around at the same time. The **window** answers the first question at a global level across all keys and is the dominant safety net for memory and latency, while the **per-key buffer** answers the second question at a local per-key level and lets you decide whether your join behaves like a “latest value per key” view or like a “recent history of events per key”.

#### 4.1 The match window: how long events stay relevant

Streams are unbounded, but your process is not, so the match window is the rule that says how long an unmatched record is allowed to stay “warm” in the cache so that late partners can still match it. A count-based window expresses this as “how many entries can we keep before we must evict something”, whereas a time-based window expresses it as “how old may an entry become before we consider it stale and drop it”. In both cases you are encoding a tolerance that comes from your domain, such as “orders are interesting for about 3 seconds after they arrive” or “we do not want more than 1 000 events buffered per side under any circumstances”.

- **Count window**: `:window({ count = N })` keeps at most `N` buffered entries per side. This is the simplest option and gives you a hard, easy-to-understand memory cap, which is valuable when you mainly care that the join cannot grow without bound and are happy to let the oldest entries fall out when that cap is reached.
- **Time window**: `:window({ time = seconds, field = "sourceTime", currentFn = os.time })` keeps each entry as long as `currentFn() - entry[field] <= time`. This is the right choice when you think in terms of freshness, for example “keep customer events for 5 seconds so late orders can still match them”, and it becomes very test-friendly when you inject a fake clock so you can step time by hand instead of waiting in real time.

The builder chooses between these shapes based on the options you provide: if you specify `count`, it builds a count window; otherwise it builds a time window using `time` (or `offset`) and `field` (defaulting to `sourceTime`). If you omit `:window` entirely, we fall back to a generous default count window so that demos do not instantly flush everything, but in real applications you should always set the window explicitly so that your retention and memory footprint match your expectations rather than surprising you later.

Garbage-collection knobs control when the window rules are enforced:

- `gcOnInsert` (default `true`) means “apply the window rules every time a new event arrives”, which gives you very timely expirations and unmatched emissions but asks the CPU to do a bit of extra work on each insert.
- `gcIntervalSeconds` lets you say “also run a sweep every so often even if no new records arrive”, which is important when you use time windows and want expirations to fire even in quiet periods. You should only disable `gcOnInsert` if you provide a periodic scheduler and are comfortable with expirations being delayed until the next tick.

Whenever the window decides that an entry has overstayed its welcome—because the cache is too full or because the entry has become too old—we emit an expire packet on `QueryBuilder:expired()` with a reason like `evicted` or `expired_interval`. Watching this stream tells you whether your window is too small (records expire before they can match) or too generous (records almost never expire), and in many debugging sessions this side channel is as important as the main joined stream itself.

#### 4.2 Per-key buffers: distinct vs. non-distinct per join key

On top of the global window, each side of the join maintains a small **per-key buffer** (a ring) for every join key. This buffer answers the second question: how many records sharing the same key you are willing to keep at the same time, which in turn controls whether your join behaves like a “latest snapshot per key” or like a “short history of events per key”. When you set `bufferSize = 1`, you get distinct-by-key behavior where each new arrival for a key overwrites the previous one, the overwritten entry is evicted with `reason="replaced"` and sent down the expired stream, and only the newest record can ever match future partners. When you set `bufferSize > 1`, multiple arrivals per key can coexist in the buffer until the window or the buffer itself prunes them, and each new partner can see several recent events instead of just the last one.

You configure this at the high level through `onSchemas` by using the table form for each schema, for example:

```lua
:onSchemas({
  customers = { field = "id", bufferSize = 10 },
  orders    = { field = "customerId", bufferSize = 3 },
})
```

In this configuration the customers side behaves like a short history that can hold up to ten recent customer records per id, while the orders side keeps up to three recent orders per customer id. If you set `distinct = true` inside one of these tables it is treated as sugar for `bufferSize = 1`, and if you set `distinct = false` without a buffer size we fall back to the default size so that you explicitly opt into non-distinct behavior rather than drifting into it by accident.

On insertion the buffer first checks whether it has room for the new record; if the buffer is already full for that key, it removes the oldest entry, emits that entry with `reason="replaced"`, and then appends the new record. When a partner arrives on the other side, the join matches that partner against **all** buffered entries for the key, which means that increasing `bufferSize` increases fan-out and allows one partner event to join with several waiting records that share the same key. Conversely, decreasing `bufferSize` down to `1` forces a “latest only” behavior where only the most recent entry per key can match, which is often what you want when you are modeling state rather than individual events.

The match window and the per-key buffer work together: the buffer prunes “horizontally” within each key, choosing between a distinct or non-distinct view of that key, while the window prunes “vertically” across all keys, deciding how many or how old entries in total are allowed to stay warm. Because count windows now count buffered entries, a large buffer per key will consume the global window faster, so if you want “latest per key” semantics you typically set `bufferSize = 1` and pick a window that mainly caps total growth, and if you want “every event per key” semantics you intentionally allow a larger `bufferSize` and choose a window large enough to hold the richer history without surprising early evictions.

With these two levers in mind—window for “how long/how many overall” and per-key buffers for “how many per key”—reactive joins become an intuitive extension of SQL thinking that happens continuously over time instead of only at query execution.



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
2. **Always call `:onSchemas`**: explicit mappings keep projection/alignment and observability accurate.
3. **Choose a window**: count windows are simpler; time windows mirror real-world latency. Tune `gcOnInsert`/`gcIntervalSeconds` to balance freshness vs. throughput.
4. **Handle expirations**: subscribe to `builder:expired()` if unmatched/aged-out records matter to your domain.
5. **Inspect both streams**: when debugging layered joins, observe both the joined stream and the expiration stream. Match status metadata, projection metadata, and the dedup cache help you correlate how the join pipeline behaves over time.
