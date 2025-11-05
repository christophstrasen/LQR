# Per-Key Buffer Refactor Plan

Goal: make join cache behavior explicit and configurable via per-key record buffers (ring buffers), with no silent drops and expire events for every removal. Default stance: non-distinct (buffers >1) is allowed; distinct is just a buffer size of 1. We will update call sites rather than keep backward-compatible shims.

## Scope and Phasing
1) **Low-level core (JoinObservable)**: swap single-record caches for per-key ring buffers, unify eviction semantics, and emit expire on every removal (including overwrites). Keep matching logic symmetric and configurable per side.
2) **High-level Query API**: extend `onSchemas` to accept per-schema options (`field/selector`, `perKeyBufferSize`, `distinct` sugar). Remove `onField/onId` remains already done. Plumb normalized config into core.
3) **Tests & docs**: update expectations, add coverage for overwrite/replace expirations, per-key buffers, and asymmetric configs. Refresh guides/examples.

## Detailed Steps
### Core changes (JoinObservable)
- Replace per-side cache tables with per-key buffers:
  - Data shape: `cache[key] = { entries = {...}, head/tail or array }` (FIFO ring). Track matched per entry.
  - Config: per-side `perKeyBufferSize` (1 = distinct; n = ring cap; default 10). Left/right share the same default unless overridden.
- Insert path:
  - Compute key via selector.
  - Append entry to buffer; if buffer is at capacity, evict oldest entry and emit `expire(reason="replaced")` (with the old entry’s data and matched flag) + unmatched if applicable. Log warning: `Default buffer size <size> reached for <schema>.<key>. If you did not set this buffer size deliberately to achieve a more distinct ID behavior, you may want to review your settings and consider a larger buffer.`
  - Mark new entry `matched=false`, store key/schemaName.
  - If other side has buffered entries with same key, emit matches against each buffered partner (fan-out) on arrival.
- Expiration/GC:
  - Count windows count entries (not distinct keys); interval/predicate iterate per entry.
  - `flushBoth`/completion/disposal emit expire for every remaining entry.
  - Ensure periodic/insert GC walks buffers and removes entries with expire events.
- Expire semantics:
  - New reason `replaced` for overwrite evictions.
  - No silent drops; every removal path emits to `expired` subject.
  - Overwriting resets matched on the new entry to false; the displaced entry retains its own matched flag in the expire record.

### High-level Query (builder)
- Extend `onSchemas` map entries to support tables:
  - Shorthand string `schema = "field"` → `{ field = "field" }` with default perKeyBufferSize (10).
  - Table form: `{ field = "...", perKeyBufferSize = N, distinct = bool }` where `distinct=true` forces size=1; `distinct=false` picks default (10) if none provided.
  - Reject missing field/selector; require per-schema coverage as today.
- Normalize options:
  - Produce per-side configs passed to core (`perKeyBufferSize` per schema/side).
  - Remove legacy behaviors; update all call sites/tests to the new shape.

### Tests
- Update existing join facade/core specs to new API shapes.
- Add coverage:
  - Overwrite emits `expire(reason="replaced")` and does not silently drop.
  - Count windows count entries when perKeyBufferSize>1.
  - Asymmetric buffers (left=1, right=3) still match and expire correctly.
  - Flush/completion emits expire for all buffered entries.
  - Selection/describe reflects new key config structure.

### Docs & Examples
- Update high-level API docs to describe per-key buffers, distinct vs non-distinct, defaults, and new expire reason.
- Refresh examples (including viz demos) to use `onSchemas` table form where needed.
- Document migration: `onField/onId` gone; `onSchemas` table entries replace them; overwrite now emits `replaced` expirations.

## Open Decisions to Resolve During Implementation
- Default `perKeyBufferSize` when unspecified: 1 (distinct) vs a small >1 vs unbounded.
- `matched` reset policy on overwrite: keep current reset or make sticky? Decide and document.
- Whether count windows should remain distinct by key when perKeyBufferSize=1 (likely no—uniform entry counting is simpler).
