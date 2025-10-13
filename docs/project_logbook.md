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

## Day 3 – Schema-Aware Chaining

### What we built
- **Schema metadata everywhere:** Every stream entering `JoinObservable` now goes through `Schema.wrap("schemaName", observable, { idField = ... })`, guaranteeing `record.RxMeta.schema`, IDs, versioning, and source times exist before we touch caches. This let us drop the legacy `left/right` pair objects entirely and emit `JoinResult`s keyed by schema name.
- **JoinResult utilities:** Added `Result.clone`, `Result.selectSchemas`, and `result:attachFrom(other, schemaName, rename)` so we can persist composite records across joins without rebuilding tables. Payloads are shallow-copied (top-level table only), and metadata is cloned/renamed automatically.
- **Explicit chaining helper:** `JoinObservable.chain(resultStream, { from = { { schema = "orders", renameTo = "...", map = fn }, ... } })` forwards one or more schema names from an upstream join into a new schema-tagged observable. It subscribes lazily, respects unsubscription, and optionally maps each payload (projector → renamed to `map`). This replaces the manual subject plumbing we started with.
- **Multi-schema experiment:** `experiments/multi_join_chaining.lua` now chains customers → orders → payments using `chain`. We forward both the enriched order and the raw customer schema so the downstream join can access whichever representation it needs.
- **Docs/tests:** `docs/low_level_API.md` documents `JoinResult` helpers and the `chain` syntax. Unit tests cover schema-name cloning/renaming, lazy subscription behavior, per-schema mapping, and multi-schema forwarding work correctly.

### Key insights
1. **Schema-driven joins > positional pairs:** Emitting schema-indexed records makes cascading joins far less brittle, especially when the same physical schema appears multiple times (self-joins). A simple schema-naming convention plus helpers provides the structure SQL’s `AS` clause gives us.
2. **Chaining needs lifecycle discipline:** Wrapping the piping logic in `JoinObservable.chain` ensures backpressure and disposal behave like any other Rx operator. Subjects were easy to prototype but too fragile for real use.
3. **Result utilities unlock higher-level APIs:** With `selectSchemas`/`attachFrom` in place, we can start designing richer chaining patterns or DSLs (e.g., multi-key `on` clauses) without touching the join core again.

### Open questions / next steps
- Extend `chain` to accept declarative `on` maps or multi-key declarations so downstream joins can reference schemas directly (`customers.id`, `orders.customerId`) without hand-written selectors.
- Consider auto-generating schema name suffixes (configurable format) when callers omit `renameTo`, especially for self-joins.
- Explore helper sugar (`Result.flatten`, metrics/logging hooks) once we have a few more real-world scenarios.

## Day 4 – Identity Enforcement & Alias Cleanup

### What we built
- **Guaranteed record IDs:** `Schema.wrap` now demands an `idField` or `idSelector` (unless the record already carries `RxMeta.id`). Missing or failing IDs trigger a warning and the record is dropped before it reaches the join. The wrapper also stamps `RxMeta.idField` for debugging, so downstream stages know which field produced the identifier.
- **Schema-first cache metadata:** The join core no longer tracks `record.alias`. Cache entries, expiration packets, and `JoinResult` plumbing all use `record.schemaName`, which removed a bunch of legacy terminology and eliminated ambiguous fields in expirations (`packet.schema` replaces `packet.alias`).
- **Result API modernization:** `Result` now exposes `schemaNames` and `selectSchemas`. The internal metadata table is `RxMeta.schemaMap`, keeping the naming consistent everywhere.
- **Examples/tests updated:** Every example/experiment wraps sources with explicit ID info, including functional selectors (partition/localId). Specs were upgraded with helpers that auto-derive IDs, and new tests ensure `Schema.wrap` enforces IDs (field-based and selector-based) while dropping invalid payloads.
- **Love2D visualization harness:** Added `viz/main.lua` and `viz/pre_render.lua` to rasterize schemas in real time. Inner grids track customers/orders while an outer overlay highlights joined and expired events with separate fades/palettes.
- **Config-driven knobs:** Centralized palette choices, stream delays, expiration windows, fade durations, and grid geometry in `viz/sources.lua`, along with hundreds of synthetic customers/orders (IDs 101–400+) so demos stay lively.

### Key insights
1. **Identity must enter at the edge:** Trying to invent IDs inside the join leads to nondeterministic caches. Forcing callers to declare the identifier in `Schema.wrap` keeps retention logic predictable and documents the domain contract.
2. **Schema terminology beats “alias”:** Once we stopped storing `record.alias`, it became obvious how many code paths and docs were still mixing metaphors. Consolidating on schema names made debugging expiration packets and downstream joins simpler.
3. **Metadata hygiene prevents leaks:** The temporary regression (misusing `record` inside `publishExpiration`) reminded us how easy it is to stomp on cache entries when variable names overlap. Keeping clear structures (`recordEntry`, avoids those side effects.
4. **Visualization needs strict metadata:** Because every record passed through `Schema.wrap`, the renderer could introspect without special cases. Hover tooltips became meaningful once we carried full customer/order/record tables rather than pre-formatted strings.

### Open questions / next steps
- Offer helper sugar for generated IDs (e.g., hash-based) so callers without natural keys can opt in consciously rather than writing selectors by hand.
- Revisit the `JoinObservable.chain` API to reduce boilerplate now that schema IDs are guaranteed—maybe forward composite records when appropriate.
- Document best practices for `idSelector` error handling (e.g., metrics hooks) so dropped records remain observable in production.
- Stream real join output (not just synthetic tables) into the visualization to validate lifetimes under real backpressure.
- Add keyboard/GUI controls (pause, speed sliders, schema filters) so we can inspect heavy joins without editing code.


## Day 5 – Visualization Pipeline Polish

### Highlights
- **Config-driven everything:** `viz/source_recipes.lua` now owns grid/fade settings and per-layer stream descriptors (color, observable, track fields, hover metadata). The renderer and pre-render logic simply ingest this table—no more bespoke wiring.
- **Observable helpers:** New `viz/observables.lua` and `viz/observable_delay.lua` build the demo streams, normalize join/expired records, and inject randomized delays without patching upstream `lua-reactivex`.
- **Flexible layouts:** Added `startOffset` at the grid and layer level so scenarios can offset ID placement without touching code. `viz/pre_render.lua` automatically derives the right mapper.
- **Lean pre-render core:** Removed legacy extractors and redundant helpers; a single schema-aware builder now handles track/label/hover/meta selection for every stream.
- **Testing + hygiene:** Extended `tests/unit/pre_render_spec.lua` to cover delay behavior and start offsets, ensuring viz regressions get caught in pre-commit/CI. Vendor edits to `lua-reactivex` were reverted, keeping the upstream dependency clean.

### Next steps
1. Document the stream descriptor schema (fields, optional `track_schema`, hover syntax) and consider loading it from scenario files.
2. Add more headless specs for hover payload rendering and expired-stream shaping to keep the visualization safe to refactor.
3. Surface multiple scenarios/configs via CLI flags or a toggle now that the pipeline is fully data driven.

## Day 6 – GC Controls & Docs

### Highlights
- **GC knobs:** Added `gcOnInsert` (default true) so retention sweeps can be skipped on insert and left to periodic GC. Joined this with `gcIntervalSeconds`/`gcScheduleFn`; debug logging now uses a dedicated `debugf` instead of warning the world.
- **Scheduler clarity:** Low-level docs now spell out the need for a scheduler to run periodic GC and describe the per-insert toggle. GC code warns when no scheduler is available but keeps per-insert retention as the safety net.
- **Testing:** New GC spec exercises `gcOnInsert=false` with a scheduled sweep and keeps interval-based GC coverage. 

### Takeaways
1. **GC is policy + plumbing:** Retention policy lives in `expirationWindow`; GC controls (interval, scheduler, sweeps on insert) are execution concerns and stay at join level.
2. **Per-insert sweeps are safety-first:** With small caches they’re cheap; periodic GC exists for idle periods but shouldn’t be the only guard unless the host is sure about memory headroom.
3. **Lifecycle correctness:** Cleaned up completion/disposal so both join and expired streams close reliably, flushing leftovers; added TODO to measure GC cost and auto-tune onInsert/interval based on load.

## Day 7 – Viz GC UX & Scheduler Fixes

### Highlights
- **Periodic GC in viz:** Left-join scenario now passes a `gcScheduleFn` powered by the Love2D scheduler; fixed delay units (seconds, not ms) so ticks actually fire. Enabled `gcOnInsert=false` in the demo to showcase periodic sweeps.
- **GC status header:** Viz header now shows GC mode (interval + scheduler requirement, insert sweeps on/off, or insert-only). Legend/grid were shifted to accommodate the extra lines.
- **Debug visibility:** Core GC logs switched to DEBUG-only stderr; periodic ticks and per-insert sweeps are visible without spamming warnings.

### Takeaways
1. **UI mirroring runtime state helps:** Seeing GC mode in the viz immediately flags misconfigurations (missing scheduler, insert-only mode).
2. **Scheduler ergonomics:** Passing host-specific schedulers (`gcScheduleFn`) is the least brittle way to demonstrate periodic GC across environments; auto-detect remains best-effort only.
