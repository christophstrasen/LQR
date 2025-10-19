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

See `viz_high_level/demo/headless.lua` (or the shim in `viz_high_level/examples/headless_trace.lua`) for a deterministic trace that wires all pieces together without Love2D.
