# Experimentation Logbook – Lua Reactive Joins

Project: **LiQoR** – Lua integrated Query over ReactiveX  
A Lua library for expressing complex, SQL-like joins and queries over ReactiveX observable streams.

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
- Broaden join types (left/right/anti/full) and allow per-join join window policies (time-based or count-based) to balance correctness vs. resource limits.
- Emit normalized `key` (derived from `on` selector) alongside `left/right` entries so downstream stages don’t need to re-derive join fields.
- Explore cascading joins in code, ensuring key selectors and cache options propagate cleanly.
- Investigate multi-source joins (more than two streams) to compare ergonomics and resource usage with binary chaining.

## Day 2 – JoinObservable Hardening

### Highlights
- **Modular core:** Broke the monolithic `JoinObservable/init.lua` into focused helpers (`strategies`, `expiration`, `warnings`) and kept only the observable factory + key-selector/touch helpers in the entry module. This makes reasoning about join behavior, warning plumbing, and expiration logic far easier.
- **Powerful expiration join windows:** Replaced the lone `maxCacheSize` knob with `joinWindow` modes (`count`, `interval`, `time`, `predicate`). Each mode emits structured expiration packets (“evicted”, “expired_interval”, “expired_time”, etc.) and replays unmatched rows according to the strategy, giving users stronger control over correctness join windows. A new LuaEvents experiment demonstrates every mode with timestamped data.
- **Test depth:** Suite now covers default joins, functional selectors, count/interval/time/predicate retention, nil-key drops, malformed packets, warning suppression, merge ordering + failure, matched-record guarantees, and manual disposal. Everything runs cleanly via `busted tests/unit/join_observable_spec.lua`.

### Key learnings
1. **Visibility beats silence:** Dropped packets (nil keys, malformed merge output, predicate errors) must surface via warnings; use the shared logger tag (`join`) and `Log.supressBelow("error", fn)` in tests to mute noise without sacrificing production observability.
2. **Retention defines correctness:** Framing cache limits as `joinWindow` made it clear only “warm” records yield trustworthy joins. Providing time/predicate policies keeps the API flexible without leaking complexity into the core.
3. **Composable architecture pays off:** Moving strategies/expiration/warnings into their own modules and offering a custom merge hook gave us the confidence to expand features without bloating `init.lua`, and paved the way for future extensions (per-side policies, metrics).

### Decisions recorded
- Keep nil-key entries as warnings + drops; expiration events fire when cached records (matched or not) age out.
- Enforce merge contracts with hard assertions; failing to return an observable is programmer error.
- Close `expired` when the main subscription unsubscribes to avoid dangling listeners.
- Default `joinWindow.mode = "time"` to a 60-second TTL over the `time` field; callers can override `ttl`, `field`, or `currentFn` as needed.

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
- **Config-driven knobs:** Centralized palette choices, stream delays, expiration join windows, fade durations, and grid geometry in `viz/sources.lua`, along with hundreds of synthetic customers/orders (IDs 101–400+) so demos stay lively.

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
1. **GC is policy + plumbing:** Retention policy lives in `joinWindow`; GC controls (interval, scheduler, sweeps on insert) are execution concerns and stay at join level.
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

## Day 8 – Join strictness, caching perf, and Rx sharing

### Highlights
- **Join robustness:** `JoinObservable` now flushes caches on merge errors, cancels periodic GC on all terminal paths, backfills RxMeta for mapper outputs, and warns when chain mappings reference missing schemas. `withWarningHandler` scopes handler changes safely.
- **Chain efficiency:** `JoinObservable.chain` caches per-schema lookups and clones once per mapping, reducing allocations for fan-out scenarios while keeping mapper isolation intact. Tests cover mapper error disposal, fan-out isolation, and missing-schema warnings.
- **Rx fork expansion:** Added `publish`, `refCount`, and `share` to the vendored lua-reactivex (mirroring RxJS semantics), with Lust-based tests wired into the upstream test runner. Guidance added to low-level docs on using `publish():refCount()`/`share()` to fan out cold streams without duplicate upstream work.
- **Module clarity:** Split the join engine into `JoinObservable.core` and the chain helper into `JoinObservable.chain`; call sites now import `JoinObservable.init` explicitly (no shim). Fixed viz/examples to use the new entry point.

### Takeaways
1. **Lifecycle discipline:** Flushing caches and cancelling timers on all terminal signals avoids hidden state and stray work after errors/completion.
2. **Hot vs cold clarity:** Shared streams should use explicit multicast helpers; we added them to the fork and documented when to apply them in our join pipelines.
3. **Metadata fidelity:** Mapper outputs now retain schema metadata even when returning bare tables, keeping downstream joins predictable.

## Day 9 – High-level viz pipeline (WIP) for multi-join projection & stacking

### Highlights
- **New high-level viz path:** Spun up a separate high-level visualization pipeline (keeping the low-level intact) aimed at pluggable, multi-join rendering; wired Love2D entrypoint and headless renderer to consume adapter/runtime snapshots.
- **Projection map & enrichment:** Derived projection domain/fields from the first join’s ON map, threading projection metadata into normalized viz events. Events now carry `projectionKey`/`projectable` only when the schema has a known projection field, using actual record payloads (so orders with customerId project even without the customer schema present).
- **Renderer behavior:** Headless/Love2D renderers draw only projectable inners/borders; non-projectables are counted. Legends show total/projectable/non-projectable per schema and projectable/total counts for match/expire. Header includes projection info and non-projectable summaries.
- **Stacked layers fixed:** Borders now sort by layer and inset per layer; refund/order stacked joins render as two outlines when projection data is available. Snapshot hover metadata retains native ids/schemas.
- **Examples/tests:** Headless trace now runs through the real Query+adapter pipeline. Added projection map and projectable vs non-projectable tests (including non-projectable events that don’t draw), merged enrichment coverage, and kept the suite green.

### Takeaways
1. **Projection must use real payloads:** Resolving projection keys from record fields (not just schema presence) allows deeper joins to project even when the primary schema isn’t in the event.
2. **Non-projectables stay visible via counts:** We avoid misplacing borders by hiding non-projectables from the 2D grid but surfacing them in counts/legend; projection keys are required for drawing.
3. **Layering clarity across dimensions:** Sorted/inset borders make stacked joins readable, while counts/metadata acknowledge that some joins live in other key domains—flattened into 2D without pretending they occupy the same plane.

## Day 10 – Auto-zoomed grid, color mixing parity, and Love2D polish

### Highlights
- **Decay-aware color mixing:** The high-level renderer now records ingest timestamps and decays mix weights over time, matching the low-level viz’s additive blending. Overlapping sources/matches blend colors when they happen close together; stale hues fade toward the neutral background.
- **Consistent grid visuals:** Every cell now renders a default light-gray inner rectangle with borders, so decayed events reveal the same grid state as untouched cells. The Love2D drawer blends event colors toward that baseline, making fade-outs intuitive.
- **Auto zoom & sliding join window:** Runtime tracks active IDs (based on projection keys and intensity) to decide whether a 10×10 or 100×100 grid is needed. It slides the join window with a 20% forward buffer and only reevaluates every two seconds, keeping the view stable. Manual configs still work via `maxColumns/maxRows`.
- **Digit-based labels:** Column labels now represent the higher-order digits (beyond the row granularity), while row labels display the last 1–2 digits depending on zoom level. The grid aligns IDs to these digit boundaries, so headers are meaningful at a glance.
- **Love2D integration:** The on-screen viz uses the runtime’s auto zoom, draws consistent backgrounds, and displays headers/legends derived from the snapshot. Headless traces also consume the same snapshot data, ensuring parity between scripted runs and the UI.

### Key learnings
1. **Consistent baselines reduce cognitive load:** Drawing default cells (and blending fades toward that state) keeps the grid legible even as events decay, avoiding ghosts or abrupt flashes.
2. **Timestamped mixing unlocks richer storytelling:** Recording event ingest times (and allowing configurable half-lives) makes color blending and opacity meaningful rather than arbitrary; this paved the way for future animation ideas.
3. **Auto zoom needs clear alignment rules:** Splitting ID digits into row/column labels forced us to align grid starts to row multiples and define row/column counts precisely, otherwise the text got misleading. This alignment also stabilized sliding behavior.

### Next steps
- Exercise the Love2D viz against real (non-deterministic) streams to validate mixing/zoom heuristics; tune half-life/buffer defaults as needed.
- Reintroduce “outer layer” annotations from the low-level viz so anti joins and expirations have more expressive outlines.
- Expand documentation/headless trace guidance to explain how to read the new grid, labels, and decay behavior, potentially with annotated snapshots.

## Day 11 – Composite sizing + deterministic blending

### Highlights
- **Bottom-up cell sizing:** The high-level drawer now derives every cell dimension from fixed per-zoom specs (inner core, border, gap, padding) instead of trimming from a hard-coded box. This keeps the inner payload readable even when multiple join layers fire in 10×10 mode and shrinks gracefully in 100×100 mode.
- **Deterministic color mixing:** `CellLayer` sorts overlapping layers by timestamp and blends them with decay-aware weights before reintroducing the neutral background. Match/expire bursts no longer flicker between solid colors; simultaneous events settle into stable mixes that fade smoothly over their TTL.
- **Replayable fidelity:** With stable geometry and blending, snapshots from the headless renderer now look identical to the Love2D viz, so we can ship/record traces that accurately reflect on-screen behavior—something we couldn’t promise yesterday when zooming or overlapping events.
- **Stronger regression coverage:** New busted specs capture the draw metrics, confirm inner fill thickness stays constant across zooms, and assert the blending math stays stable as TTLs decay. Headless renderer tests now see the same behavior as the Love2D front-end.

### Key learnings
1. **Geometric invariants beat heuristics:** Encoding border/gap sizes explicitly gives predictable visuals and makes tests independent of magic numbers—future layout tweaks simply adjust the layout table.
2. **Order-independent blending avoids surprises:** Treating each layer as a weighted contribution (rather than sequential overrides) keeps the viz believable when multiple schemas light up a cell at the same time.
3. **Tests should match concepts, not literals:** By computing expectations from the layout metadata we eliminated brittle pixel constants and made the suite track the intent (fixed inner core, per-layer growth) instead of accidents of the old implementation.

## Day 12 – Zones 2.0: grid-aware shapes, timing, and purity

### Highlights
- **Grid-aware zone generator:** Zones now map shapes (continuous/flat/bell/circle) directly to grid IDs, dropping projection shims. Coverage thins fills by shuffling the full mask, creating gaps without shrinking the shape.
- **Deterministic spatial/thin logic:** Coverage no longer slows emission rate or collapses inward; it selects a spread of cells across the mask. Random modes use a fixed seed, and rate shapes support constant/linear/bell aliases to keep schedules predictable.
- **Time controls made sane:** Introduced `playbackSpeed` as the single pacing knob (ticksPerSecond fallback). Zone timelines use `t0/t1`, `rate`, and `rate_shape` over `PLAY_DURATION`; stamping `sourceTime` aligns joins and visual TTLs. Love runner gained a shared clock with a post-complete fade budget to keep visuals expiring after streams finish.
- **Cleaner mapping defaults:** Zones own the ID ordering per shape; demos no longer carry mapping hints. Two-circle/two-zone demos lock the join window (10×10), build time-based join windows on `sourceTime`, and use unified payloads (no custom projection fields).
- **Color refresh on repeats:** `CellLayer` refreshes and recomputes color on repeated adds, so rapid re-emits stay bright instead of dimming due to TTL decay.

### What we learned
1. **Uniform rate vs. coverage:** Rate should reflect the intended pace, not how many cells are filled. Separating rate from coverage produces the right “gappy but steady” flows.
2. **Shape-aware ordering matters:** Emission order belongs to the shape (spiral/Z-order for circles, monotonic for lines); moving mapping into the generator avoids per-demo hacks and keeps joins honest.
3. **One clock to rule visuals and joins:** Sharing a deterministic clock across scheduler, sourceTime stamps, and renderer is essential to keep fades, expiries, and joins aligned—especially in Love where the first frame’s `dt` can jump.
4. **Docs and tests must track intent:** Added explainer notes on streaming join counts vs. unique IDs, and adjusted generator tests for the new coverage semantics. This keeps expectations aligned with the deterministic model we want to present.

## Day 13 – Logging clarity, expiration semantics, and coverage

### Highlights
- **Event-level viz logging:** Added explicit `viz-hi` logs for source/match/unmatched/expire events; join logs now show `[expire] matched=true|false reason=...` to disambiguate cache removals. Snapshot logging is opt-in (`logSnapshots`) to keep Love runs quiet while headless traces still log frames. Dedup suppression was removed so repeat inputs/frames can be seen when enabled.
- **Expiration semantics tightened:** Matched rows now expire like others; expire packets carry `matched` so consumers can filter “never matched” vs “was matched.” Added a new spec to assert all inputs eventually expire and that matched flags flow through. Expiration/viz events include the flag. We also rediscovered a cache limitation: per-key overwrites drop prior payloads silently (no expire/unmatched), so repeated ids lose earlier versions—needs a future fix.
- **Docs clarified:** Explainer updated with lifecycle terminology (input/match/unmatched/expire), schema provenance via `RxMeta.schema`, and a clear definition of “joined record” including anti-join behavior. Viz README reorganized with clearer TTL knobs, demo defaults, and per-layer join coloring.
- **Viz polish:** Added per-layer join colors (blends of participating schema colors), per-layer legend rows/counts, dynamic fade padding based on max TTL factors, and clarified Love/default knobs.

### Takeaways
1. **Observability with intent:** Logging now differentiates match status on expiration, and viz event logs are explicit (“draw source/join/expire”), making churn analysis and debugging clearer.
2. **Cache hygiene predictable:** With matched rows expiring and a `matched` flag in packets, downstreams can reconcile positives vs negatives and build retry/backfill logic cleanly.
3. **Known gap:** Overwriting cached keys drops prior payloads without an expire/unmatched signal. We need a retention strategy that preserves version visibility (emit replace events or keep bounded per-key queues).
4. **Optional noise:** Snapshots/logging are now opt-in per environment (headless vs Love), reducing log spam while preserving the ability to trace everything when needed.

## Day 14 – Per-key buffers, distinct semantics, and high-level knobs

### Highlights
- **Per-key buffers with full expiration signaling:** Join caches now use small per-key ring buffers (`perKeyBufferSize`, default 10) instead of single entries; every removal path emits on the expired stream (`evicted`, `expired_*`, `replaced`, `completed`/`disposed`/`error`), closing the old silent overwrite gap.
- **High-level `on` with oneShot knobs:** The Query API’s `on` accepts rich entries like `{ field = "id", bufferSize = 10, oneShot = false }`, so “latest only” vs “recent history” is an explicit choice. String shorthand stays, but table form is the canonical way to align high-level intent with low-level per-key buffers.
- **Symmetric GC and richer counts:** `gcOnInsert` still defaults to true, but per-insert sweeps now walk both left and right caches; periodic GC reuses the same helper. The viz pipeline counts expirations by reason and surfaces them in the outer legend/header, so we can see at a glance how much churn comes from `evicted` vs `expired_interval` vs `replaced`, etc.
- **Two-circles demo wired to lifetimes:** The `two_circles` scenario uses the shared join TTL, per-layer `visualsTTLFactors`/`visualsTTLLayerFactors`, and timed snapshots (“rise/mix/trail”) to make overlaps and expirations readable. Love defaults (playback speed, locked 10×10 grid) are tuned to show per-key buffers, GC symmetry, and expiration-reason counts without overwhelming the viewer.

### What we learned
1. **Two levers, two questions:** Windowing answers “how long/how many entries overall stay warm,” while per-key buffers answer “how many events per key stay warm at once.” Keeping those concerns separate made configuration less mysterious.
2. **Every removal deserves a story and a count:** With explicit expire packets and per-reason counts, we can now reconstruct why a record left the join and see aggregate churn broken down by `reason`, which is far more useful than a single expire total.
3. **High-level sugar should describe intent:** Encoding distinctness as `bufferSize`/`distinct` on `on` means the same call captures both join fields and “latest vs history” semantics, matching how people actually think about joins.
4. **Symmetric GC and stretched visuals help humans:** Sweeping both caches on insert makes stale ownership less surprising while periodic GC covers idle periods; decoupling visual TTL from logical TTL lets demos exaggerate lifetimes just enough for people to see what’s happening without lying about when the engine actually drops records.

## Day 15 – WHERE semantics and final visualization layer

### Highlights
- **High-level WHERE implemented on the builder:** Added `QueryBuilder:where(predicate)` as a single, post-join filter. It runs after all joins and before `selectSchemas`, using a schema-aware row view (`row.<schema>`, always a table, plus `_raw_result` escape hatch). Selection-only queries are supported by wrapping single-schema records into `JoinResult`s, so WHERE sees a consistent shape.
- **Row-view logging and safety:** WHERE predicates receive row tables where missing schemas are represented as empty tables, making `row.orders.id` safe even for left joins. We log WHERE decisions at INFO (`[where] keep=true/false ids=customers:1,orders:102`) using a compact schema/id summary rather than full payloads to keep logs readable.
- **Default join window knobs:** Introduced `Query.setDefaultJoinWindow` (global) and `QueryBuilder:withDefaultJoinWindow` (per-query) so multi-join pipelines can share a consistent retention policy without repeating `:joinWindow` on each step. Step-level `:joinWindow` still overrides, and `describe()` now surfaces both the effective per-join windows and the GC configuration derived from the default.
- **Final layer in viz: post-WHERE stream:** The visualization adapter now taps the final, post-WHERE stream via a `withFinalTap` hook and emits synthetic `kind="final"` events. The renderer treats these as a dedicated outer border layer (layer 1) with `palette.final` (default green), so the outer ring always represents “what a final subscriber would see,” even for single-schema queries.
- **Preserved join layers plus final:** We reverted to keeping the original join-stage match/unmatched events in the viz pipeline and layered final on top instead of replacing them. Join layers remain colored by blended schema palettes, and their per-layer counts/legends still reflect pre-WHERE joins, while the final layer shows post-WHERE survivors.
- **Layer semantics and legends updated:** Layer 1 is now final, join layers are shifted by +1, and `maxLayers`/draw metrics were updated to account for final + joins. The legend shows join layers from inner to outer, followed by a `Final (Layer 1)` line and then `Expired`, so the layering model is explicit in the Love2D header.
- **Three-circles demo:** Added a `three_circles` demo (customers → orders → shipments) that exercises two join layers plus the final outer layer. Both headless and Love runners are wired in, sharing the same adapter/runtime/renderer stack.

### What we learned
1. **WHERE is “just” a filter, but needs good ergonomics:** A plain Lua predicate over a row view gives us SQL-like WHERE power (cross-schema conditions, left-join nil handling) without building a query DSL. The key is to guarantee post-join placement and a stable, schema-aware row shape.
2. **Viz must separate “join mechanics” from “final result”:** Pre-WHERE join layers answer “what is the join doing?”; the final layer answers “what does my subscriber see?”. Keeping both, and making the final ring explicit, gives better intuition than trying to overload a single concept of “joined.”
3. **Layer indexing and TTLs need a story:** By reserving layer 1 for final and shifting joins inward, `visualsTTLLayerFactors[1]` clearly applies to the final ring and join layers can be tuned separately. The TTL map now has room for a dedicated `final` factor distinct from `match`.
4. **Instrumentation hooks should mirror the logical pipeline:** Having both `withVisualizationHook` (join-stage) and `withFinalTap` (post-WHERE) kept the adapter simple and made it obvious where each class of events originates. That pattern will generalize to future stages like GROUP/HAVING/LIMIT without re-plumbing the entire viz stack.

## Day 16 – GROUP BY / HAVING and grouped demos

### Highlights
- **Low-level grouping core (`groupByObservable`):** Introduced a new low-level operator that consumes a joined+filtered row stream and produces three observables:
  - an **aggregate stream** (one synthetic schema per group with `_count` and `_sum/_avg/_min/_max` under nested tables);
  - an **enriched stream** (original row view with `_count`, inline aggregates on each schema, and grouping metadata in `RxMeta`);
  - an **expired stream** (raw evictions/expirations per key for debugging).
  Windows are time-based (`time/field/currentFn`) or count-based (`count`), with `gcOnInsert`/`gcIntervalSeconds`/`gcScheduleFn`/`flushOnComplete` matching join GC semantics. Aggregate rows are tagged with `RxMeta.schema = groupName` (default `_groupBy:<firstSchema>`/`_groupBy`), while enriched rows preserve source schemas and add a synthetic `"_groupBy:<groupName>"` payload for downstream consumption.

- **Data model + tests:** Locked down the aggregate and enriched shapes in `groupByObservable.data_model` and validated them via `group_by_data_model_spec` and `group_by_core_spec`:
  - aggregate rows: `_count`, `window`, `RxMeta.{schema,groupKey,groupName,view}`, nested `_sum/_avg/_min/_max`;
  - enriched rows: top-level `_groupKey/_groupName/_count`, per-schema `_sum/_avg/_min/_max`, plus a synthetic `"_groupBy:<groupName>"` subtree mirroring aggregates.

- **High-level API integration:** Extended `QueryBuilder` with `groupBy` / `groupByEnrich` / `groupWindow` / `aggregates` / `having`:
  - grouping runs after joins and WHERE, over the row view (`row.<schema>` plus `_raw_result`);
  - `groupBy` drives the aggregate view; `groupByEnrich` drives the enriched view;
  - `groupWindow` and `aggregates` configure the grouping core;
  - `having` filters the grouped stream (aggregate or enriched) with WHERE-like semantics;
  - `describe()` now surfaces a `plan.group` section (mode, window, aggregates, having marker).
  A new `query_group_by_spec` covers basic count-window grouping, aggregates, and HAVING on both aggregate and enriched streams.

## Day 17 – LQR namespace, examples, and grouping ergonomics

### Highlights
- **LQR namespace + entrypoint:** Wrapped the core modules under an `LQR/` tree and added `LQR/init.lua` plus a root shim `LQR.lua`. `require("LQR")` now exposes `Query`, `Schema`, `JoinObservable`, `reactivex`, and a few helpers (`observableFromTable`, `get`), while tests and demos were updated to go through the namespaced paths. The bootstrap logic was tightened to resolve `LQR` and vendored deps relative to the project root instead of relying on CWD.
- **High-level lions/gazelles example:** Rebuilt `examples.lua` into a small, self-contained “animal kingdom” demo: two schemas (`lions`, `gazelles`), an inner join on `location`, a `groupByEnrich("by_location")`, and aggregation over `count_distinct` gazelles plus average lion hunger. The example uses `SchemaHelpers.subjectWithSchema` to simulate live events (subjects + `onNext` calls) and prints human-readable enriched rows, demonstrating how joins + grouping + HAVING-like predicates hang together in a real scenario.
- **Row-level aggregation refinements:** Renamed the grouping row count from `_count` to `_count_all` and introduced per-schema counts under `_count` (e.g., `_count.customers`, plus per-path maps such as `customers._count.id`). Added `count_distinct` aggregates (mirroring `sum`/`avg`/`min`/`max`) so users can configure distinct counts per path (`count_distinct = { "gazelles.id" }` → `row.gazelles._count_distinct.id`), while the existing `row_count` flag remains the switch that enables `_count_all`/`_count`.
- **Central dot-path getter:** Added `LQR.get(tbl, "gazelles._count_distinct.id")` as a tiny, generic, dot-path-safe getter for nested tables. The example uses it to keep printing expressions tidy and defensive, and it serves as a future expansion hook for more path-aware helpers.
- **Configuration validation + warnings:** Hardened configuration surfaces with warn-only validators:
  - `groupByObservable`’s aggregate config now validates keys (`row_count`, `count`, `count_distinct`, `sum`, `avg`, `min`, `max`) and emits warnings for unknown keys or wrong types. It also logs when aggregate paths don’t match any numeric data (e.g., `sum`/`avg` of a non-existent field, `count`/`count_distinct` on missing paths).
  - `QueryBuilder:joinWindow` and `:groupWindow` emit warnings on unexpected keys in the window tables, making it easier to catch typos without breaking existing callers.
  - `QueryBuilder:on` now warns when the mapping references a schema name that isn’t part of the current join, in addition to the existing coverage checks.

### Takeaways
1. **A first-class LQR module improves discoverability:** Having a single `require("LQR")` entrypoint that surfaces `Query`, `Schema`, and a couple of helpers (like `get`) makes it much easier for users to explore the library from REPLs and examples, without hunting for internal module paths.
2. **Examples should mirror real use, not just tests:** The lions/gazelles example deliberately simulates live events via subjects and shows join + group + HAVING semantics in a small, narrative scenario. This is a better teaching tool than test fixtures, and it also forced us to confront subtle behaviors (fan-out, distinct counting, average over joined rows) from a user’s point of view.
3. **Richer aggregates need clear shapes:** Separating `_count_all` from per-schema `_count` (and adding `_count_distinct`) makes the grouped rows feel more SQL-like while preserving streaming semantics. The new shapes also make it obvious when you are counting join events vs. distinct entities, which matters a lot once joins and windows interact.
4. **Lenient validation with explicit warnings hits a sweet spot:** Rather than failing hard on every typo, warn-only validation on `aggregates`, `on`, and `joinWindow`/`groupWindow` catches misconfigurations early without breaking demos or tests. It also documents the supported configuration surface implicitly via log messages, which is useful when evolving the DSL.
5. **Distinct semantics on grouped aggregates are a promising next step:** We now support `count_distinct`, but other aggregates (`sum`/`avg`/`min`/`max`) still operate per joined row. A future task is to explore optional “distinct” variants for these aggregates so grouped windows can behave even more like SQL’s `COUNT(DISTINCT ...)`/`AVG(DISTINCT ...)` over joined streams.

## Day 18 – DistinctFn aggregates and aliasable outputs

### Highlights
- **DistinctFn-enabled aggregates:** Extended `groupByObservable`’s aggregates so `count`, `sum`, `avg`, `min`, and `max` accept entries in the form `{ path = "...", distinctFn = fn(row), alias = "..." }`. `distinctFn` drives a per-entry, per-recompute distinct table so grouped windows can operate over distinct entities (SQL-like `COUNT(DISTINCT ...)` / `AVG(DISTINCT ...)`) rather than raw join rows, while `alias` mirrors the result onto a user-facing path.
- **High-level lions/gazelles refinements:** Updated `examples.lua` to express “gazelles per location” via a distinct `count` entry with `distinctFn` instead of the old `count_distinct` key, and to surface clearer aliases (`distinctGazellesCounting`, `HowHungryTheyAre`) while still keeping the canonical `_count`/`_avg` shapes for downstream joins.
- **Alias projection in the data model:** Taught the group-by data model to project aggregate aliases into both aggregate and enriched rows (and their synthetic `_groupBy:` schemas), warning when an alias overwrites an existing field. This keeps alias behavior explicit and predictable, and documents the potential clobbering in logs.
- **Configuration validation + warnings:** Kept aggregate key validation (`row_count`, `count`, `sum`, `avg`, `min`, `max`) but tightened error messages for malformed aggregate entries (non-table entries, missing `path`, non-function `distinctFn`, non-string `alias`). Non-primitive `distinctFn` results are treated as fatal for that entry, with warnings to make it obvious why a configured aggregate didn’t show up.

### Takeaways
1. **Aliases separate machine shape from human names:** Keeping `_sum/_avg/_min/_max/_count` as the canonical aggregate buckets while projecting aliases like `lions.avgHunger` or `gazelles.distinctGazellesCounting` gives us both a stable shape for joins and a friendlier surface for app code and visualizations.
2. **Distinct semantics belong with user intent:** Letting callers supply a `distinctFn(row)` per aggregate makes “distinct over what?” an explicit, local decision, avoiding another global knob. The per-recompute `seen` tables stay bounded to each group’s window, so we get SQL-like distinct behavior without leaking memory.
3. **Logbook entries should track DSL evolution:** Moving this work into a new day keeps Day 17 as the snapshot of the original `count_distinct` design while documenting how the aggregate DSL evolved toward distinctFn-based, aliasable entries in Day 18.

## Day 19 – Schema-level distinct operator, retention, and expiration/viz semantics

### Highlights
- **New schema-aware `:distinct` operator:** Added `QueryBuilder:distinct(schema, opts)` as a first-class per-schema dedupe stage with count/time windows. Duplicates are suppressed on the main stream and surfaced on `expired()` as `distinct_schema`, while survivors expire once when the distinct window flushes. Also renamed the join-level `on{ ... }` knob from `distinct` to `oneShot` to make its consume-on-match semantics explicit, decoupling it from per-key buffer sizing (keep as many warm entries per key as you like, each still used once).
- **Aggregate payloads expose `_group_key`:** Group-by aggregates/enriched synthetic schemas now mirror the grouping key as `_group_key` alongside `_count_all`, so displays don’t need to dig into `RxMeta`.
- **Example polish:** The lions/gazelles example interleaves events by `sourceTime`, uses `groupBy` (aggregate view), and logs a compact aggregate line with hunger average, last lion time, and a hunting flag; aliases were removed to keep the shape canonical.
- **Shared retention + validation:** Join, group, and distinct windows now share the same validation surface (mode, count/time, field, currentFn) and emit warn-only diagnostics on bad configs, keeping retention behavior predictable across operators.
- **Expiration + viz alignment:** Clarified that every record entering a join cache produces exactly one expired record per join step, and that multi-step joins (plus distinct) can legitimately yield more expirations than upstream emissions. Expired records carry `origin` (`join`/`distinct`/`group`) and `matched`, and the viz adapter now propagates these so we can split join vs distinct vs group expirations and align schema legend counts with true upstream emissions.

### Takeaways
1. **Dedupe belongs in its own operator, not hidden in join internals:** Moving schema-level deduplication into `:distinct` makes intent explicit (“only one observation per entity/field in this window”) and lets the join-level `oneShot=true` knob stay focused on per-key consume-on-match behavior.
2. **Time windows + distinct must not self-refresh:** Removing the “refresh on duplicate” behavior restored expected TTL semantics (“first seen wins until it expires”) and made distinct windows behave like true first-seen caches.
3. **Expired is observability, not a 1:1 mirror:** Treating `expired()` as “what left which cache, when, and why” (with `origin` and `matched`) explains why multi-step joins and distinct can produce more expirations than inputs without implying double-emits, and lets viz counters match the mental model instead of fighting it.

## Day 20 – Documentation pass and public face

### Highlights
- **New overview + Quickstart README:** Replaced the minimal root `README.md` with a proper overview of LiQoR, a runnable Quickstart example (`require("LQR")`, `Schema.observableFromTable`, `Query.from(...):leftJoin(...):on(...):joinWindow(...):where(...)`), and a short explanation of the `expired()` side channel (why you care about unmatched/expired records and tuning windows).
- **Docs folder split:** Moved the earlier exploratory docs into `LQR/raw_internal_docs/` and reserved a new top-level `docs/` folder for future, cleaned-up user-facing material. Added `docs/README.md` as a small table-of-contents pointing into key internal docs (explainer, data structures, high-level/low-level API briefs) until we have dedicated `docs/concepts` / `docs/guides` material.
- **Documentation principles captured:** Introduced `LQR/raw_internal_docs/documentation_principles.md` as the internal “how we document LiQoR” guide: layered structure (root README → `docs/` → `raw_internal_docs/`), sticky vocabulary (`record`, `schema`, `JoinResult`, `join window`, `group window`, `expired`), SQL hooks with honest streaming semantics, small set of example domains (customers/orders, lions/gazelles, zombies/rooms), and a checklist for future docs.
- **Public meta sections:** Extended `README.md` with a “Props & Credits” section (explicitly crediting `4O4/lua-reactivex` and `bjornbytes/RxLua`), an AI disclosure (where/how AI tooling was used, but confirming human review), and a short disclaimer in the slightly-doomed Knox County tone, clarifying AS-IS status and the independent, fan-made nature of the project.

### Takeaways
1. **Docs deserve a real architecture too:** Having a clear separation between overview, user docs, and internal notes should make it much easier to grow LiQoR without burying new users under Day 1–19 history.
2. **Quickstart should show observability early:** Including `expired()` and a simple `where` in the very first example nudges users toward thinking about join windows, unmatched records, and streaming semantics right away instead of treating them as advanced topics.
3. **Writing down documentation principles now saves future us:** Capturing how we want to talk about records, schemas, windows, and grouping (and which examples/domains we reuse) should keep future docs and examples from drifting into conflicting terminology or tutorial styles.

## Day 21 – First user-facing docs slice

### Highlights
- **New concepts section under `docs/`:** Drafted and iterated the first batch of user-facing concept docs: `records_and_schemas`, `joins_and_windows`, `where_and_row_view`, and `grouping_and_having`, all aligned with our documentation principles and sticky vocabulary.
- **Practical join guide:** Added `guides/building_a_join_query.md`, an end‑to‑end walkthrough that starts from schema-wrapped tables, builds a left join with a join window and `where`, and subscribes to both the main stream and `expired()` with links into lua‑reactivex / reactivex.io for follow‑up operators.
- **Grouping and `having` refined:** Tightened the `grouping_and_having.md` concept, clarified the role of the group key function, and sharpened the recommendation to prefer `groupByEnrich` as the default for per-event decisions with group context, including how `having` can combine aggregates and per-row fields.
- **Distinct/dedup conceptized:** Added `docs/concepts/distinct_and_dedup.md` to explain schema-level `distinct(schema, opts)`, its count/time windows, and how it differs from join and group windows, including first-seen semantics and `distinct_schema` expirations on `expired()`.
- **Joins as observations over entities:** Strengthened the join docs (`joins_and_windows.md`) around the idea that joins operate on **observations in a window**, not abstract entities, with a concrete 3×4=12 example per key and the reminder that “observations of a thing are not the thing itself”.
- **Multiplicity knobs clarified:** Expanded and clarified the section on `oneShot` vs `distinct` so users understand how `oneShot` limits per-record reuse inside a join cache, while `distinct` deduplicates at the schema level before/after joins and grouping.
- **Minor consistency pass:** Aligned terminology (`LQR` vs `LiQoR`), row-view descriptions, and aggregate naming (`groupResult` in both views) across concept docs, and marked truly advanced knobs (per-key buffers, time-bucketed distinct keys) as such.

### Takeaways
1. **We now have a real user-facing docs entry point:** New users can move from the README into a coherent `docs/` slice that explains records/schemas, joins/windows, row-level filters, grouping/HAVING, and distinct/dedup with consistent examples.
2. **Duplication and multiplicity are first-class concepts:** Users get a clear story for why joins can emit more rows than “1:1 IDs” suggest, and which knobs (`oneShot`, `distinct`, windows) they can use to shape that behavior.
3. **Windows are framed as layered tools, not one big switch:** Join, group, and distinct windows each have a focused role, and the docs now emphasize how they compose rather than re-explaining them in isolation in each place.
4. **Docs and implementation are in tighter sync:** The distinct operator’s behavior (first-seen, count/time windows, expired origins/reasons) and join multiplicity semantics are now described in the same language the code and tests use, reducing the risk of future drift.
