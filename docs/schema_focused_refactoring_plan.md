# Schema-Focused Refactoring Plan

This plan captures the current agreements around schema metadata for `JoinObservable` and outlines the steps required to implement them. It’s meant as a living checklist; update it as decisions evolve.

## Key Decisions (Locked-In)

1. **RxMeta container:** All system fields live under `record.RxMeta`. Agreed keys:
   - `schema` (string, mandatory): canonical name like `"customers"`.
   - `schemaVersion` (integer, optional, `nil` means “latest”). Reject/normalize away `0`.
   - `sourceTime` (number, optional): epoch seconds (or whatever the producer uses consistently). Time-based retention prefers this field.
   - `joinKey` (any): the resolved join key. Single values today; future compound keys may use tables (`{ value = {...}, parts = {...} }`).
2. **Schema prefixing:** All system-managed fields are prefixed with `Rx` to avoid user collisions; internal helpers may add more under `RxMeta` later.
3. **Mandatory schemas:** Any observable entering `JoinObservable.createJoinObservable` **must** emit records with populated `RxMeta`. The join will assert hard if metadata is missing or malformed—no silent defaults.
4. **Schema helper:** We provide a helper (e.g., `Schema.wrap(stream, schemaName, opts)`) so call sites can wrap raw observables before joining. Helper injects `RxMeta` if absent and leaves existing metadata untouched.
5. **Metadata propagation:** Expiration and match outputs forward each side’s metadata unchanged. No automatic merging of left/right; higher-level utilities (`asSchema`, aliases) can compose new schemas when desired.
6. **No default stripping:** The low-level API exposes `RxMeta` by default. A future helper may “rename” or rebuild schemas for downstream consumers, but the join itself never removes metadata.

## Implementation Steps

1. **Helper module**
   - Create `Schema.wrap(observable, schemaName, opts)` (schema name mandatory, `schemaVersion` optional).
   - Validate inputs, inject `RxMeta` when missing, preserve existing metadata if already present.
   - Emit informative errors when schema metadata is absent or invalid.

2. **Join input validation**
   - Update `JoinObservable.createJoinObservable` to assert presence and structure of `record.RxMeta`.
   - Ensure `RxMeta.schema` is a non-empty string, `schemaVersion` is `nil` or positive integer, `sourceTime` is numeric when present.
   - Reject zero-ish versions by turning them into `nil` and warning once per schema.

3. **Join key stamping**
   - After resolving the key selector, write the normalized value into `record.RxMeta.joinKey`.
   - Establish the future-friendly shape for compound keys (likely `{ value = { partName = partValue, ... }, parts = { "partName", ... } }`).

4. **Docs + context updates**
   - Extend `docs/low_level_API.md` with a “Minimum Internal Schema” section describing `RxMeta`.
   - Update `.aicontext/context.md` and any other guidance docs to reflect mandatory schema wrapping and helper usage.
   - Capture best practices for aliasing and chaining (even if not implemented yet).

5. **Examples/tests refresh**
   - Wrap every example stream through the new helper so they emit proper metadata.
   - Adjust tests (or add new ones) verifying that the join rejects metadata-free records and stamps `RxMeta.joinKey`.
   - Document how to inspect schemas in the example output (e.g., print `pair.left.RxMeta.schema`).

6. **Future work placeholders**
   - Design `asSchema`/alias helpers that can rename or merge schemas for chained joins.
   - Explore normalized emission structures once we need multi-schema records beyond `left/right`.
   - Decide whether to warn on `RxMeta.sourceTime` anomalies or let callers self-police.

Follow this sequence to keep the refactor incremental: helper first, validation, join-key stamping, documentation, then sample updates. Each step is independently testable, which helps maintain confidence while we evolve the API.***
