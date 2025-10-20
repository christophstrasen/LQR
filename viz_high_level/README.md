# High-Level Visualization

This folder now splits into a `core/` package (adapter, runtime, renderer, draw helpers) and `demo/` wiring (Love2D app + headless script + deterministic data generator) so the reusable pieces stay separate from sample entrypoints.

## Adapter expectations

- `QueryVizAdapter.attach` instruments `Query.Builder` joins via `withVisualizationHook`. We currently **require** every join step to call `:onSchemas` with explicit schema → field mappings. Those maps are how we determine projection domains and grid anchoring, so the adapter prints a warning if the plan falls back to `onField`/`onId`.
- Primary sources are derived from `QueryBuilder:primarySchemas()`. If a schema does not appear there we skip its `input` events entirely.

## Normalized events

The adapter exposes `attachment.normalized`, an observable made up of deterministic tables:

| `type`       | Additional fields                                                                                     |
|--------------|--------------------------------------------------------------------------------------------------------|
| `source`     | `schema`, `id`, `projectionKey`, `projectable`, `record`                                               |
| `joinresult` | `kind` (`"match"` or `"unmatched"`), `layer`, `key`, `left`, `right`, `schema`, `entry`, projections   |
| `expire`     | `schema`, `id`, `reason`, `entry`, projections                                                         |

`joinresult.kind` lets the runtime treat matched rows and anti-join rows consistently while still allowing different styling later on.

## Source deduplication

Primary `source` events are deduplicated by `schema::id` to avoid spamming the grid whenever a join replays cached inserts. Tokens are released once that id expires or gets flushed as unmatched, so future inserts show up as "updates". If you re-emit a record (same schema/id) before its window cycles, the adapter intentionally keeps only the first visual row to prevent flicker.

## Demo layout

- `viz_high_level/demo/simple/` keeps the original eight-event snapshot demo for smoke testing. Run `viz_high_level/demo/simple/headless.lua` to trace it without Love2D, or launch the Love app via `love . simple` (same UI as the lively demo).
- `viz_high_level/demo/timeline/` hosts the lively scheduler-driven scenario (customers → orders → shipments). `love .` (or `love . timeline` / `love . --demo timeline`) runs it, while `viz_high_level/demo/timeline/headless.lua` replays the same timeline headlessly and emits labeled snapshots throughout the run.
- Shared helper modules (scheduler, future test harnesses, etc.) live directly under `viz_high_level/demo/` so each scenario subfolder only needs to expose `build()/start()` implementations.
