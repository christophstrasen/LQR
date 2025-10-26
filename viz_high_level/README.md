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

## Zone generator (deterministic synthetic data)

We ship a small, deterministic zone generator to synthesize records for demos that opt into it (e.g., `demo/two_circles`, `demo/two_zones`). Timeline/window_zoom/simple still use hand-authored timelines. The generator lives under `viz_high_level/zones/` and is invoked via `viz_high_level/demo/common/zones_timeline.lua`. It only produces payloads; joins and visualization stay native (`QueryVizAdapter` reads the same fields it always did).

### Shapes

Supported shapes:

- `continuous`: linear span across `center ± range`, ordered ascending.
- `linear_in` / `linear_out`: weighted ramps across the span.
- `bell`: center-heavy ordering across the span.
- `flatField`: deterministic shuffle of the span (seeded).
- `circle10` / `circle100`: mask on a 10×10 or 100×100 grid; mapped to absolute ids using the provided grid config and `radius` (mask size).

### Core knobs

- `center` (number): anchor id for linear shapes; for circles we convert mask offsets around this anchor using the fixed grid.
- `range` (number): half-span for linear shapes (required for non-circles).
- `radius` (number): mask size for circles (default from shape name, e.g., `circle10` → 10).
- `coverage` (0..1): fraction of shape cells eligible for emission.
- `mode`: `"random"` (default, seeded deterministic shuffle) or `"monotonic"` (cycle through ordered cells, wrap as needed).
- `rate`: events per second over the zone’s time window (`t0..t1`). Total events ≈ `rate * (t1 - t0) * totalPlaybackTime`.
- `t0`/`t1` (0..1): normalized start/end of emission window.
- `rate_shape`: `"constant" | "linear_up" | "linear_down" | "bell"` to space timestamps over the window.
- `grid`: passed via `zones_timeline` opts: `{ startId, columns, rows }`. Circles map mask offsets into this grid; linear shapes still use absolute ids around `center`.
- `payloadForId` (function): optional; build a native payload from the chosen id. If omitted, defaults to `{ [idField] = id }`.
- `idField`: only used when `payloadForId` is absent (default `"id"`).

### Determinism and mapping

- No projection keys are injected. The generator produces plain payloads; projection/join keys are resolved by `QueryVizAdapter` via `onSchemas`.
- Random mode uses a fixed seed (LCG) so runs are repeatable.
- Circles are grid-aware: mask cells carry row/col offsets, converted to ids via `startId + col*rows + row`. The window should be locked for these demos to keep shapes stable.

### Modes and wrap

- Random mode: build a deterministic shuffle of eligible cells; if `rate` drives the count past the number of cells, we wrap through the shuffled list again.
- Monotonic mode: walk the ordered list and wrap as needed. High rates will revisit cells in order.

### Usage in demos

`viz_high_level/demo/common/zones_timeline.lua` calls the generator with the demo’s zones and grid config, appends a completion event, and returns events/snapshots/summary. Demos that use zones (currently the circle and two-zone examples) supply zones plus a fixed grid (e.g., `startId=0, columns=10, rows=10`) when they need shapes to align to the window. Other demos (timeline/window_zoom/simple) keep their hand-authored timelines. The demo `build()` still sets up schema-aware subjects via `SchemaHelpers.subjectWithSchema`, so emitted payloads are native.

Example zone (orders circle aligned with customers):

```lua
{
  label = "ord_circle",
  schema = "orders",
  center = 55,
  radius = 7,
  shape = "circle10",
  coverage = 0.3,
  mode = "random",
  rate = 8,
  t0 = 0.1,
  t1 = 0.6,
  rate_shape = "linear_down",
  idField = "id",
  payloadForId = function(id)
    return { id = id, orderId = 500 + id, customerId = id, total = 30 + ((id % 4) * 5) }
  end,
}
```

### Grid and window locking

For shape demos, we fix the window in `loveDefaults` (`maxColumns`, `maxRows`, `startId`, `lockWindow=true`) so ids land predictably. Auto-zoom is suppressed when `lockWindow` is set; the runtime still honors adjustInterval/visualsTTL for fades only.

### Summary fields

`ZonesTimeline.build` returns `events`, `snapshots`, and a summary with totals, per-schema counts, and warnings (e.g., missing circle range). It also carries a `mappingHint` (currently `"linear"`/`"spiral"`) for debugging only; renderers do not consume it.
