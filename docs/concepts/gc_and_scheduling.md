# Garbage collection and scheduling

Join, group, and distinct windows rely on cache eviction to enforce retention. This page explains how garbage collection (GC) runs and how to provide a scheduler so time-based expirations continue during traffic lulls.

## When GC runs

- **On insert (default):** `gcOnInsert = true` runs a retention sweep on both sides every time a record arrives.
- **Periodic:** Set `gcIntervalSeconds` to sweep caches even when no new records arrive. Requires a scheduler.
- **Opportunistic fallback:** If no scheduler is available, only insert-time sweeps run; time-based expirations pause when traffic pauses.

Per-insert and periodic GC can run together: periodic ticks keep time windows moving during lulls, while insert-time sweeps keep memory bounded between ticks.

## Config knobs

- `gcOnInsert` (default `true`): disable only if you provide a periodic scheduler and can tolerate delayed expirations.
- `gcIntervalSeconds`: interval (seconds) between periodic sweeps. Off when nil/false.
- `gcScheduleFn(delaySeconds, fn)`: scheduler callback. Should run `fn` after `delaySeconds` (seconds). May return an object with `unsubscribe`/`dispose` or a cancel function; it will be invoked on disposal.
- Scheduler lookup: if `gcScheduleFn` is not provided, LQR tries `rx.scheduler.get():schedule(fn, delayMs)` (e.g., `TimeoutScheduler`). If none is found, periodic GC is disabled and a warning is logged.

## Supplying a scheduler

Provide a thin adapter for your host’s timer API:

```lua
local function scheduleFn(delaySeconds, fn)
  local handle = timers.setTimeout(fn, delaySeconds * 1000) -- e.g., luv/ngx timers
  return function()
    timers.clearTimeout(handle)
  end
end
```

Pass it via `joinWindow({ gcIntervalSeconds = 1, gcScheduleFn = scheduleFn })` (or the equivalent group/distinct window options).

## Behavioral impact

- **Unmatched emissions:** Left/right/anti emissions for time windows occur when a record expires; without periodic GC they wait until the next insert.
- **Memory vs CPU:** Per-insert GC keeps memory bounded but costs CPU on every arrival; periodic GC shifts work to ticks and can allow higher peaks between sweeps.
- **Time windows:** `currentFn` is still used to measure age; GC just triggers the sweep.

## Verify your setup

- Start a join with a time window, set `gcIntervalSeconds`, pause input, and ensure expirations still flow.
- Look for the startup warning about missing schedulers; if you see it, provide `gcScheduleFn` explicitly.
