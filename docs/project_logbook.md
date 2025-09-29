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

### Focus
- **Test depth:** Added coverage for default inner-join behavior, functional key selectors, cache eviction (two variants), nil-key drops, malformed packet guards, warning suppression, merge error propagation, subscription teardown, matched-record expiration guarantees, custom merge ordering, and merge contract validation. Suite grew from 2 → 12 specs and now runs cleanly via `busted tests/unit/join_observable_spec.lua`.
- **Observability knobs:** Introduced `warnf` plus `JoinObservable.setWarningHandler` so nil keys and malformed packets emit structured warnings in production yet stay muted in CI/unit tests. Added lifecycle guarantees that `expired` emits completion on unsubscribe and never signals matched records.
- **CI readiness:** With deterministic tests and warning control, we can wire `busted tests/unit` into local git hooks and CI without flaky noise, sealing the “hardening” work for this iteration.

### Key insights
1. **Drop-on-floor events need visibility:** Silently ignoring malformed packets or nil keys leads to ghost data bugs. Emitting warnings (and testing them) exposed this behavior early and gives ops a place to hook custom loggers.
2. **Custom merge hooks are a power-user feature:** Allowing stream reordering/buffering is valuable, but enforcing the “must return an observable” contract prevents subtle runtime failures. Tests now cover both the happy path (respecting order) and the failure path (asserting early).
3. **Lifecycle symmetry matters:** The expiration observable should mirror the primary join: it errors when the join errors and completes when either the sources finish or the consumer unsubscribes. Codifying this prevents downstream resources from leaking.

### Decisions captured
- **Nil key policy:** Keep dropping entries whose selector resolves to `nil`, but emit a warning so the condition is observable; no expired events or join output for these records.
- **Warning API:** Expose `JoinObservable.setWarningHandler(handler)` and return the previous handler, letting tests silence logs and production integrate with existing logging infrastructures.
- **Merge contract enforcement:** Treat “merge returned a non-observable” as a runtime assertion that halts execution; we intentionally *don’t* downgrade this to a warning because it indicates a programming error.
- **Expiration semantics:** Ensure matched records never surface in `expired`, unmatched ones emit exactly once (eviction/completion), and manual unsubscribe closes the subject immediately.
