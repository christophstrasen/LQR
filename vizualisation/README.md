# High-Level Visualization

This package visualizes streaming joins by turning normalized events into grid snapshots. It separates reusable core pieces from demo wiring so you can reuse the runtime/renderer without dragging along Love2D entrypoints.

## Architecture
- **core/**: houses the mechanics. `query_adapter` hooks into joins and emits normalized events the viz can consume. `runtime` maintains projection/grid state so we know where to place things. `headless_renderer` + `draw` turn that state into snapshots and pixels.
- **demo/**: contains Love runners, headless scripts, and data generators. These feed the core but are optional if you just want the visualization plumbing.

## Core concepts and flow
1) **Adapter expectations**  
   The adapter is the bridge from joins to viz. Call `QueryVizAdapter.attach(builder)` on your query builder. Always supply `:using` with explicit schema→field maps so we can compute projection domains (what ids live on the grid). Primary schemas come from `QueryBuilder:primarySchemas()`; anything else is skipped for `input` events.

2) **Normalized events (what the renderer consumes)**  
   - `source`: “a record arrived.” Includes `schema/id`, the `projectionKey` we’ll place on the grid, whether it’s `projectable` (key resolved), and the original `record`.  
   - `joinresult`: “a join emission happened.” Carries `kind` (`"match"` or `"unmatched"`), which border `layer` to draw, the join `key`, the participating payloads (`left/right`), and projection metadata so we know where to show it.  
   - `expire`: “a cached record aged out.” Includes `schema/id`, `reason`, the removed `entry`, and projection info so the viz can show the expiry burst on the right cell.  
   The `kind` field keeps matches and anti-joins on the same pipeline while allowing different styling.

3) **No deduplication of sources**  
   We now let every `source` emission through, even if it reuses the same `schema::id`. Re-emits often carry meaningful changes and should redraw; the renderer will simply refresh the same cell instead of dropping the event.

4) **Runtime → Renderer → Draw**  
   Runtime ingests normalized events, tracks the window and projection grid, and the headless renderer builds a snapshot (cells, layers, legend). The Love runner draws that snapshot; headless scripts log it for tests and snapshots.

## Visual fades (TTL)
- Base TTL = `(visualsTTL or adjustInterval) * visualsTTLFactor`; if you omit `visualsTTL`, we fall back to the adjust cadence so fades still have a duration.
- Per-kind scaling (optional): `visualsTTLFactors = { source, joined, final, expire }` multiplies the base for inner fills (sources), join borders (joined layers), the outer post-WHERE ring (final), and expire borders.
- Per-layer scaling (optional): `visualsTTLLayerFactors = { [layer] = factor }` multiplies join/final borders per depth so outer/final can linger differently than inner ones.
- Leave the maps out to keep all factors at 1. Example: two_circles boosts match TTLs, shortens expire TTLs, and lifts the outermost match layer via `visualsTTLLayerFactors[2]`.

## Demo defaults (Love/headless)
Each demo exports `loveDefaults`; `demo/common/love_defaults.lua` just merges the table. These defaults configure how the runner plays and renders:
- `label`: window title shown by the runner.
- `visualsTTL`: base fade duration; defaults to `adjustInterval` if unset.
- `visualsTTLFactor`: multiplies `visualsTTL` to stretch or shrink all fades.
- `visualsTTLFactors`: optional per-kind multipliers for source/joined/final/expire layers.
- `visualsTTLLayerFactors`: optional per-border-layer multipliers on top of the joined/final TTLs.
- `adjustInterval`: how often the layout/zoom logic can run; also used as TTL fallback when `visualsTTL` is nil.
- `playbackSpeed` / `ticksPerSecond`: pacing of demo events; pick one style per demo.
- `clockMode`: whether the clock is driven by Love frames or the demo driver.
- `clockRate`: multiplier applied to the chosen clock mode.
- `totalPlaybackTime`: optional total duration for timeline-based demos.
- `maxColumns`, `maxRows`, `startId`: grid dimensions and origin.
- `lockWindow`: keep the grid anchored instead of auto-zooming.
- `backgroundColor`: optional RGBA background for Love runs.
- `windowSize`: optional Love window size.
- Other scenario knobs live beside the defaults in each demo module file.

## Demos at a glance
- `demo/simple/`: eight-event snapshot; quick smoke test. Run headless (`demo/simple/headless.lua`) or Love (`love . simple`).
- `demo/timeline/`: customers→orders→shipments with a scheduler; `love .` (or `love . timeline`) or headless replay (`demo/timeline/headless.lua`).
- `demo/window_zoom/`: auto-zoom behavior over a sliding window.
- `demo/two_circles/` and `demo/two_zones/`: grid-locked shapes via the zone generator; headless scripts emit labeled snapshots.
- Shared plumbing (driver, scheduler, zone timeline, defaults) lives under `demo/common/`.

## Zone generator (circle/zone demos)
Lives in `vizualisation/zones/`, invoked via `demo/common/zones_timeline.lua`. It synthesizes payloads only; joins/projection stay native.
- Shapes: `continuous`, `linear_in/out`, `bell`, `flatField`, `circle10/100`—pick how ids spread across the grid.
- Knobs: `center`, `range` (linear), `radius` (circles), `coverage`, `mode` (`random` seeded / `monotonic`), `rate`, `t0/t1`, `rate_shape`, `grid { startId, columns, rows }`, `payloadForId` (optional), `idField`.
- Determinism: seeded LCG; circles map mask offsets into the fixed grid; lock the window in `loveDefaults` for stable shapes.
- Output: events, snapshots, summary (counts, warnings, `mappingHint` for debugging only).
