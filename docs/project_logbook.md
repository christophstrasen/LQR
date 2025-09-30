# Experimentation Logbook – Lua Reactive Joins

## Day 1 – Foundations

### Topics explored
- **LuaEvent streaming basics:** Built `combineLatest_tables_test.lua` and `combineLatest_events_test.lua` to understand converting LuaEvent emitters into Rx observables, adding delays, logging payload schemas, and treating each trigger as a hot stream.
- **ReactiveX operator study:** Reviewed `combineLatest`, `merge`, `window`, `scan`, `flatMap`, `flatMapLatest`, `sample`, `with`, `partition`, `amb`, and related subjects. Focused on how “payload agnostic” operators rely on user-provided predicates, accumulators, or selectors to impose structure.
- **Join prototypes:** Implemented `join_lua_events_test.lua` (simple inner join) and `join_lua_events_options_test.lua` (configurable join type, bounded caches, LuaEvent inputs). Tested inner vs. “outer-only” outputs, cache eviction behavior, and logging clarity.

### Key takeaways
1. **Structure matters even in “payload-agnostic” Rx:** Operators like `combineLatest` or `scan` treat values as opaque blobs, but any meaningful logic (joins, filters, aggregations) requires self-describing payloads. Tables with named fields, explicit `schema` tags, and consistent `id` keys make downstream composition practical.
2. **LuaEvents are a viable event bus for Rx:** Wrapping them with `rx.Observable.fromLuaEvent` plus a cooperative scheduler lets us simulate asynchronous streams, merge them, and bridge into Rx operators with minimal glue.
3. **Stateful joins demand caching + eviction:** Inner joins only need a per-key cache per side, but outer/anti joins must also decide when to emit unmatched records. Introducing configurable cache limits (e.g., `maxCacheSize`) and emitting “dead-letter” rows on eviction keeps memory bounded at the cost of completeness—an acceptable trade-off for streamed data.
4. **Declarative “on/joinType” options unlock composability:** A simple options table (`{ on = "id", joinType = "inner|outer", maxCacheSize = N }`) paired with a normalized key selector makes `createJoinStream` reusable and nestable. Adding a standard `key` field to emitted pairs will make future cascading joins trivial.
5. **Join semantics can be layered like functions:** Even without a DSL, composing joins (`InnerJoin(A, LeftJoin(B, OuterJoin(C, D)))`) reads naturally and mirrors SQL. A future API could wrap our `createJoinStream` helper to provide fluent sugar while retaining the same underlying mechanics.

### Open questions / next steps
- Broaden join types (left/right/anti/full) and allow per-join window policies (time-based or count-based) to balance correctness vs. resource limits.
- Emit normalized `key` (derived from `on` selector) alongside `left/right` entries so downstream stages don’t need to re-derive join fields.
- Explore cascading joins in code, ensuring key selectors and cache options propagate cleanly.
- Investigate multi-source joins (more than two streams) to compare ergonomics and resource usage with binary chaining.

## Day 2 – JoinObservable Hardening

### Highlights
- **Modular core:** Broke the monolithic `JoinObservable/init.lua` into focused helpers (`strategies`, `expiration`, `warnings`) and kept only the observable factory + key-selector/touch helpers in the entry module. This makes reasoning about join behavior, warning plumbing, and expiration logic far easier.
- **Powerful expiration windows:** Replaced the lone `maxCacheSize` knob with `expirationWindow` modes (`count`, `interval`, `time`, `predicate`). Each mode emits structured expiration packets (“evicted”, “expired_interval”, “expired_time”, etc.) and replays unmatched rows according to the strategy, giving users stronger control over correctness windows. A new LuaEvents experiment demonstrates every mode with timestamped data.
- **Test depth:** Suite now covers default joins, functional selectors, count/interval/time/predicate retention, nil-key drops, malformed packets, warning suppression, merge ordering + failure, matched-record guarantees, and manual disposal. Everything runs cleanly via `busted tests/unit/join_observable_spec.lua`.

### Key learnings
1. **Visibility beats silence:** Dropped packets (nil keys, malformed merge output, predicate errors) must surface via warnings; exposing `setWarningHandler` lets tests mute noise without sacrificing production observability.
2. **Retention defines correctness:** Framing cache limits as `expirationWindow` made it clear only “warm” records yield trustworthy joins. Providing time/predicate policies keeps the API flexible without leaking complexity into the core.
3. **Composable architecture pays off:** Moving strategies/expiration/warnings into their own modules and offering a custom merge hook gave us the confidence to expand features without bloating `init.lua`, and paved the way for future extensions (per-side policies, metrics).

### Decisions recorded
- Keep nil-key entries as warnings + drops; matched records never emit expiration events.
- Enforce merge contracts with hard assertions; failing to return an observable is programmer error.
- Close `expired` when the main subscription unsubscribes to avoid dangling listeners.
- Default `expirationWindow.mode = "time"` to a 60-second TTL over the `time` field; callers can override `ttl`, `field`, or `currentFn` as needed.
