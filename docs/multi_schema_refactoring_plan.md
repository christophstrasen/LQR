# Multi-Schema Refactoring Plan

Goal: move from positional `{ left, right }` join outputs to schema-indexed records so we can chain joins, preserve schema names, and evolve the `on` contract later. This plan assumes we can break the current API (no backward compatibility required).

## Guiding Principles
1. **Schema-first:** Every emitted record exposes a map of schema names → payloads plus metadata describing which schemas are present.
2. **Deterministic helpers:** Callers must never poke into internal tables; provide helpers (`JoinResult.get("schema")`, etc.) so future structural tweaks stay localized.
3. **Stage work incrementally:** Touch the core once (introduce new record structure), then migrate strategies/examples/tests in waves to keep diffs reviewable.
4. **Leave `on` alone for now:** Focus on the data container. Once schema-indexed records exist, we can revisit richer key selectors.

## Refactor Steps

### 1. Baseline inventory (DONE)
- ✅ `rg "pair\.left"` sweep complete; all examples/experiments/tests now use `result:get("schemaName")`.
- ✅ Strategies and expiration logic updated to work with `JoinResult`.
- ✅ Helpers (`Schema.wrap`, tests) now expect schema name first, enforce per-record IDs, and return schema-tagged observables.

### 2. Introduce a schema-aware result container
- Create `JoinObservable/result.lua` with:
  - Constructor `Result.new()` returning `{ RxMeta = { schemas = {} } }`.
  - Methods `attach(schemaName, record)`, `get(schemaName)`, `schemas()` iterator, and serialization helpers.
  - Logic to merge `record.RxMeta` into `Result.RxMeta.schemaMap[schemaName]`, preserving ids/join keys/sourceTime.
- Update `JoinObservable/init.lua` to build/emit `Result` objects instead of plain tables. `handleMatch` returns a `Result` that attaches left/right schema payloads; unmatched emissions attach only their side.

### 3. Update join strategies
- Refactor `JoinObservable/strategies.lua` so `strategy.onMatch/emitUnmatched` receive `Result` builders rather than raw pairs.
- Ensure anti-join variants still emit Result objects even when one side is `nil`.

### 4. Adjust expiration + cache representation
- Cache entries currently store `{ entry, matched, key }`. Extend them with `schemaName` so result assembly knows which schema they belong to.
- Expiration events should emit `Result` objects with a single schema attached (instead of `{ side, entry }`). Update `expiredStream` consumers/tests accordingly.

### 5. Migration sweep: internal callers (DONE)
- ✅ `JoinObservable/init.lua`, `expiration.lua`, `strategies.lua`, and helpers now emit/consume `JoinResult`.
- We skipped transitional adapters because everything migrated in one pass.

### 6. Public surface migration (DONE)
- ✅ All examples/experiments now bind to schema names via `result:get`.
- ✅ `tests/unit/join_observable_spec.lua` reworked; added new specs for `JoinResult`/`Schema.wrap` chaining.
- ✅ Docs updated (`docs/low_level_API.md`, `.aicontext/context.md`, this plan).

- ✅ `JoinResult` now exposes `clone`, `selectSchemas`, and `attachFrom` (shallow copy of payload tables, fresh metadata per schema).
- ✅ `JoinObservable.chain` wraps the Rx plumbing for forwarding schema names (now supporting multi-schema lists), handling lazy subscription and allowing optional per-schema map functions.
- ✅ Docs/tests updated; `experiments/multi_join_chaining.lua` now exercises the chaining helper instead of manual subjects.
- Remaining work:
  1. Evaluate whether we want helper sugar for `options.on` (per-schema field lists, multi-key joins).
  2. Consider additional `JoinResult` utilities (`flatten`, debug printers) once real-world usage stabilizes.

## Verification Checklist (run at each milestone)
1. `rg "pair\.left"` — confirm no references remain outside transitional helpers.
2. `rg "side =="` — ensure logic no longer depends on left/right strings except for logging legacy warnings.
3. `busted tests/unit/join_observable_spec.lua` — primary regression suite.
4. Run all `examples/*.lua` and `experiments/*.lua` manually to verify output readability.

Keep this doc updated as we execute each step; append notes when a step completes or changes scope. This ensures future contributors understand why we reworked the data structure and where to extend it next (e.g., schema-aware key selectors).***
