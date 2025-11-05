# Reactive Event Query System – Briefing

This briefing captures the principles we discussed for an RxLua-backed event query layer that works with Starlit LuaEvents and may be used later by WorldScanner. It focuses on goals, constraints, and design choices so far, then closes with an updated example API.

## Goals (please confirm/clarify)

1. **Build upon reactiveX/Lua-ReactiveX** its core principles and API, both internally and in the exposed interface
2. Introduce minimal **SQL-Like interface sugar functions** e.g. ":InnerJoin" ":onDuration", explicit `onSchemas` mapping for keys
3. Ship pre-defined **event stream composition functions** that power functions
4. Introduce the **minimum stateful behavior** required for the expanded functionality
5. Is **fully testable in a headless environment**
6. Nice to have: Introduce a **render pass** behavior that allows to "flag" some events e.g. with "color" or other metadata that reacts to "merging" via joins or filtering

## Design criteria & constraints (please confirm/clarify)

- **Headless-friendly:** Core query engine runs in plain Lua 5.1 with zero Project Zomboid dependencies so it can be unit-tested outside the game.
- **Lua-ReactiveX-native runtime:** Builder/DSL is a thin veneer; internally everything is an `Observable`/`Subscription`, and advanced users can access raw Rx primitives.
- **Immutable fluent API:** Every builder call returns a new query definition (no hidden mutation), matching Rx operator chaining expectations.
- **Interoperable outputs:** Queries expose both high-level conveniences (`into`) and the underlying observable so consumers can compose further in Rx.
- **Graceful backpressure & lifecycle:** Provide all standard Lua-ReactiveX operators like (`throttle`, `buffer`, `sample`) and ensure `subscribe()` always returns disposable subscriptions.
- **Error routing:** User predicates/effects are wrapped in `pcall` and errors flow through `onError`, enabling `catch`, `retry`, etc. just like in standard Lua-ReactiveX
- **Starlit stays data-light:** The existing LuaEvent hub remains unchanged; the query engine listens via adapters but does not force Starlit to track extra state.
- **Payload shape is opaque:** Queries treat events as generic tables (stream id + arbitrary keys). Domain logic (SquareCtx, RoomCtx) lives in users of the system.
- **Minimal dependencies:** Lua-ReactiveX (and its scheduler) and Starlit are the only third-party pieces introduced; everything else ships with the module.

Let me know if any constraints need relaxing or if new ones (performance budgets, memory caps, etc.) should be captured.

## Design Decisions and insights to Date (guidance, however not set in stone)
- **Lua-ReactiveX** We will use https://github.com/4O4/lua-reactivex / https://luarocks.org/modules/4o4/reactivex as our ReactiveX implementation
- **LuaEvent** We will use https://github.com/demiurgeQuantified/StarlitLibrary/blob/main/Contents/mods/StarlitLibrary/42/media/lua/shared/Starlit/LuaEvent.lua as the key primitive and "stream data" to operate on
- **Testing via schedulers:** Virtual-time scheduler or deterministic clock may be required for unit tests—plan to expose a hook to inject one.
- **Join semantics custom:** Lua-ReactiveX lacks keyed joins, so we will provide bespoke helpers (with timeout windows) layered atop core operators.
- **Bridge adapter:** `observableFromLuaEvent(luaEvent)` converts any Starlit LuaEvent into an Rx Observable, handling `Add`/`Remove`.
- **`into` as sugar:** `query:into(bucket)` desugars to `query:tap(function(x) bucket[#bucket + 1] = x end)` and still returns an Observable for further chaining.
- **Callback compatibility:** `query:onEach(fn)` (alias for `tap`) keeps the callback mental model while remaining 1:1 with Rx semantics.
- **Error handling:** All user-provided functions (filters, side effects, visualization) run through `pcall`; failures emit via `onError` instead of throwing.
- **Lifecycle handles:** plain `subscribe` always returns the Rx Subscription so callers control teardown.
1. **DSL Naming:** For the new "higher order functions" that "merge observed streams"we would use SQL-inspired verbs (`select`, `from`, `joinOn`)

## Decisions Pending / Need Confirmation

1. **Join surface:** Preferred API for keyed joins? (e.g. `query:innerJoin(otherQuery, keyFn, timeout)` vs. dedicated helper like `join.squareId(queryA, queryB)`.)
2. **Scheduler injection:** Do we expose scheduler choice per query, or configure a global default with overrides for tests only?
3. **Stateful sinks:** Should `into` support limits/eviction policies (ring buffer size, distinct keys) or leave that to user code?

Please clarify these before we codify the API.

## Lua-ReactiveX-Compatible Example - QUITE OUTDATED

Below is a condensed version of “Use Case 2 + 3” from `proposed_api.lua`, rewritten so every step is an Rx Observable while still feeling DSL-friendly.

```lua
local rx = require("rx")
local Observable = require("rx.observable")

local Query = require("EventQuery") -- hypothetical module we’re designing
local WorldScanner = require("WorldScanner")
local Starlit = require("Starlit")

-- Adapter: wrap the existing LuaEvent feed.
local nearbySquares = Query.fromLuaEvent(
	Starlit.Events.WorldScanner.onSquareFrom["ws.square.nearby"]
)

-- Define a reusable scanner (returns a new Query/Observable; original left untouched).
local kitchenFinder = nearbySquares
	:where(function(ctx)
		local square = ctx.square
		if not square or not square.getRoom thenrefCount() -- Rx native; still accessible
			return false
		end
		local room = square:getRoom()
		return room and room:getName() == "kitchen"
	end)
	:publish() --turn to "hot" observable that can begin to multicast emissions.
	:refCount() -- Rx native; still accessible

WorldScanner.registry["my.kitchenFinder"] = kitchenFinder

-- Consumer: subscribe, fill a bucket, and perform a side-effect.
local allFoundSquares = {}

local subscription = kitchenFinder
	:tap(function(ctx)
		if ctx.square and ctx.square.AddWorldInventoryItem then
			ctx.square:AddWorldInventoryItem("Base.Axe", 0.5, 0.5, 0)
		end
	end)
	:into(allFoundSquares) -- sugar for tap + append
	:throttle(0.5)        -- backpressure friendly
	:subscribe(function(ctx)
		print(("[WS] kitchen square %s recorded"):format(tostring(ctx.square)))
	end, function(err)
		print("[WS] kitchen finder error", err)
	end)

-- Later: subscription:unsubscribe()
```
