# High-Level `GROUP BY` / `HAVING` Semantics (Draft)

This briefing captures the current design direction for extending the high-level query API with
`GROUP BY` / `HAVING`-style functionality on top of Lua-ReactiveX. It is intentionally focused on
streaming semantics and API shape rather than low-level implementation details.

The core idea is:

- We already join and filter **live event streams** using `Query.from(...):joins():onSchemas():joinWindow():where(...)`.
  - We now want to **aggregate over sliding windows** in a way that feels SQL-like, but remains
  honest about streaming: results are continuous, windows are explicit, and group state lives in
  memory.
- We provide **two views** over grouped state:
  - an **aggregate view** (one record per group/window update, SQL-style); and
  - an **enriched event view** (each event carries its group’s live metrics).

Where SQL collapses rows into one per group, our reactive system keeps the streaming nature while
letting mod logic ask “what does this event’s herd look like right now?”.

---

## 1. Position in the high-level pipeline

Conceptually, grouping is a **post-join, post-WHERE** operation:

1. `FROM` / root source(s):
   - `Query.from(source, "schema")`
2. Join steps:
   - `:innerJoin(...)` / `:leftJoin(...)` + `:onSchemas({ ... })` + per-step `:joinWindow(...)`
3. Row-level filtering:
   - `:where(function(row) ...)` over the **row view** (schema-aware, outer-join safe).
4. **Grouping** (new):
   - `:groupBy(keyFn)` defines group keys and switches the pipeline into aggregate view.
   - `:groupByEnrich(keyFn)` defines the same grouping but returns enriched events.
   - `:groupWindow(windowOpts)` configures the group window (time- or count-based).
   - `:aggregates(aggregateConfig)` declares which aggregate values to compute.
5. Aggregate-level filtering:
   - `:having(...)` over the current view (aggregate rows or enriched events).
6. Projection:
   - `:selectSchemas(...)` or a future `:selectAggregates(...)`.
7. Subscription / sinks:
   - `:subscribe(...)`, `:into(...)`, visualization hooks, etc.

**Important:** the **join window** (`joinWindow`) and the **group window** (`groupBy(..., opts.window)`)
are **independent**:

- join window: how long unmatched records stay warm in join caches so they can still match;
- group window: over which slice of time/events we aggregate rows that share a group key.

Grouping works purely over the **joined + filtered row stream**.

---

## 2. Group keys: user-facing vs engine-facing

We treat group keys in two layers.

### 2.1 User-facing key function

At the DSL level we want a simple, row-view-based API:

```lua
local grouped =
  Query.from(animals, "animals")
    :where(function(row)
      return row.animals.type == "Elephant" or row.animals.type == "Zebra"
    end)
    :groupBy(function(row)
      return row.animals.type -- "Elephant" or "Zebra"
    end, {
      window = { time = 10, field = "sourceTime", slide = 1 },
    })
```

**Contract for `keyFn(row)` (user view):**

- Input: row view (same as `where` gets).
- Output:
  - A **primitive** (`string | number | boolean`) representing the group key.
  - May be `nil` (in which case the row is dropped from grouping with a warning).
- Must be **pure and cheap**:
  - no side-effects;
  - deterministic for the same row;
  - no blocking I/O.

### 2.2 Engine-facing cache key

Internally, grouping keeps a map:

```lua
groupKeyCanonical -> aggregateState
```

We restrict keys to primitives; tables and other types are rejected explicitly so cache behavior
stays easy to reason about:

- Wrap `keyFn` in `pcall`:
  - on error: log a warning with schema/ids and **drop the row** from grouping.
- Normalize result:
  - primitives → used as-is;
  - `nil` → drop from grouping and log a warning including schema/ids;
  - any other type (tables, functions, userdata, etc.) → drop and log a warning that group keys
    must be primitives.

**Design intent:** keep the user API ergonomic (`function(row) return row.customers.id end`),
while keeping the underlying cache keys simple, stable, and debuggable.

---

## 3. Group windows: separate from join windows

In SQL, GROUP BY runs over a finite result set. In streaming, groups must have a **window**:
we cannot keep infinite history per key.

We already have join windows (`:joinWindow`) for the join caches. For grouping we will introduce
**group windows** with their own configuration, distinct from join windows.

### 3.1 Window types (initial scope)

We aim for two primary window modes:

1. **Sliding, time-based windows**

- Window defined by:
  - `time` (duration in seconds);
  - `field` (which timestamp to look at, e.g. `"sourceTime"` or a payload field).
   - This is a **per-key sliding window** over event time, applied on the grouped stream, not the raw sources.

2. **Count-based, fixed-size windows**

- Window defined by:
  - `count` (maximum number of recent events per key to keep in the group window).
- Conceptual behavior:
  - For each key we keep the **last N events** that passed into the grouping operator.
  - When a new event arrives and the buffer is full, we evict the oldest event for that key from
    the group window and update metrics accordingly.
- This behaves like a sliding window over **event index** rather than time and is often easier to
  reason about for “last N actions per player”-style use cases.

We keep group-window design intentionally parallel to `joinWindow`, but **not shared**:

- join window protects the **join cache** from unbounded growth;
- group window defines the **analytics horizon** for aggregates.

### 3.2 Time source and consistency with joins

For joins, we already support `currentFn` and a timestamp field to operate in (logical) event time.
Grouping should mirror those capabilities and limitations:

- default: event time taken from a field (e.g. `sourceTime`);
- overrideable: `currentFn` for tests or specialized scenarios;
- processing-time windows can be modeled via `currentFn` if needed (no extra mode required).

**Consistency constraint:** join windows and group windows should see **the same notion of time**.
We cannot “fix” events that lingered in a large join window and only later reach grouping already
looking old. However, the grouping layer can:

- detect when a join window for any upstream join is **larger** than the configured group window;
- log a **warning** that some events may arrive into the group window already older than the group
  window length, which can lead to immediate eviction from grouping.

---

## 4. One grouping vs multiple groupings

We explicitly support **multiple, independent groupings** over the same joined row stream.

Conceptually:

```lua
local base =
  Query.from(customers, "customers")
    :leftJoin(orders, "orders")
    :onSchemas({ customers = "id", orders = "customerId" })
    :where(function(row)
      return row.customers.segment == "VIP"
    end)

local perCustomer =
  base:groupBy(function(row) return row.customers.id end, { window = { time = 10 } })

local perRegion =
  base:groupBy(function(row) return row.customers.region end, { window = { time = 60 } })
```

- `perCustomer` and `perRegion` are **siblings**, each with:
  - its own group window;
  - its own aggregate state;
  - its own HAVING / projection.
- This maps directly to Rx fan-out: one upstream observable, multiple grouped projections.


**Important design choice:** each grouping yields its **own stream**; we do **not** try to stuff
multiple groupings into one compound “Franken-record” with misaligned updates.

---

## 5. Two views over grouped state

Once we maintain per-key group state, there are two natural projections:

1. **Aggregate view** — “one record per group update” (SQL-like).
2. **Enriched event view** — “every event, plus its group aggregates”.

We intend to support both.

### 5.1 Aggregate view (group state stream)

This is closest to classic SQL GROUP BY. For each group key and window, we maintain aggregate
values and emit them as they change.

**Conceptual shape (payload returned by `result:get(groupName)`):**

```lua
aggregateRow = {
  key = <groupKey>, -- canonical form (string/number)

  -- Optional human-friendly name/label for the group.
  -- Default: stringified key. Can be overridden via configuration.
  groupName = <string>|nil,

  -- Aggregated values derived from the rows in the current group window.
  -- Shape mirrors configured aggregates and uses prefix tables per aggregator:
  --   - _count         : group size (always present)
  --   - <schema>._sum  : sum for configured fields under that schema
  --   - <schema>._avg  : average for configured fields under that schema
  --   - <schema>._min  : minimum for configured fields under that schema
  --   - <schema>._max  : maximum for configured fields under that schema
  --
  -- Example for a "battle" schema with nested combat/healing fields:
  --
  -- aggregateRow = {
  --   key = "battle:zone42",
  --   groupName = "battle",
  --   _count = 7,
  --   battle = {
  --     combat = {
  --       _sum = { damage = 81 },
  --       _avg = { damage = 13.5 },
  --     },
  --     healing = {
  --       _sum = { received = 124 },
  --     },
  --   },
  -- }

  window = {
    start = <number>, -- event-time boundary
    end   = <number>, -- event-time boundary
  },

  -- optional raw state for power users:
  _raw_state = <engine-private table>,
}
```

Default behavior (subject to tuning):

- **Per-record updates**: whenever a row enters/exits the window for a key, we recompute aggregate
  values and emit an updated aggregate for that key.
- **Periodic sweeps (future)**: similar to join windows, grouping may support an optional
  `gcIntervalSeconds` to expire old data even when no new records arrive. This affects *when*
  evictions happen, but not the core “update-on-insert” semantics.*** End Patch*** Comment to=functions.apply_patch  ಶ್ರೀ  ахы  коз  uestID  உட  to=functions.apply_patch  Alternating assistant role  Invalid tool call, missing or invalid JSON.  Use the arguments field to provide JSON arguments.  Or, if this tool doesn't take parameters, use an empty object.  Error: 400 Bad Request  Ndjson  JSON  Json  JSON Object  Json object  JSON object  A JSON object  JSON format  JSON object with keys  JSON.  JSON?  JSON!  JSONObject  JSON data  JSON dictionary  JSON map  JSON structure  JSON-ish  JSON,"workdir":"/home/cornholio/projects/Lua-ReactiveX-exploration"}  Or just  JSON  {}  {"foo": "bar"}  {"command": "ls"}  {"arguments": {"command": "ls"}}  {"arguments": {}}  {"arguments": {"foo": "bar"}}  {"arguments": {"workdir":"/home", "command":"ls"}}  {"arguments":{"command":["bash","-lc","ls"]}}  {"command":["bash","-lc","ls"]}  {"":""}  {"invalid":"json with trailing comma",}  {"invalid":"json with single quotes"}  {"invalid": "json with comments // no"}  {"invalid": "json, but keys not in the schema"}  {"command":"ls","timeout_ms":1000}  {"workdir":"/home","command":"ls"}  {"tool_uses":[{"recipient_name":"functions.shell_command","parameters":{"command":"ls","workdir":"/home"}}]}  JSON-style  json  jsonify  JSON'  assistant to=functions.apply_patch ***!
- Optionally emit “final” aggregates when a group’s window becomes empty and the group is evicted.

**HAVING over aggregate and enriched views (single API):**

- A `having`-style predicate sees **the current view**:
  - when you use `groupBy(...)`, `having` receives `aggregateRow`;
  - when you use `groupByEnrich(...)`, `having` receives `enrichedEvent`.

Example over aggregates:

```lua
:groupBy(keyFn, opts)
  :having(function(g)
    return (g._count or 0) >= 5
  end)
```

This is analogous to SQL’s `HAVING COUNT(*) >= 5`, but evaluated continuously over a sliding window.

### 5.2 Enriched event view (event + group context)

Streaming systems have a superpower SQL doesn’t: every event can carry **live group context**.

For each incoming row:

1. We update the group state for its key.
2. We emit an **enriched event** that combines:
   - the original row (or row view), and
   - the latest aggregate values for its group.

**Conceptual shape (row view enriched in-place):**

For enriched events we do **not** expose a separate aggregate-values tree. Instead, we:

- attach group-wide fields at the top level of the row view; and
- enrich each schema table with `_sum` / `_avg` / `_min` / `_max` subtables.

Example:

```lua
enrichedEvent = {
  -- group-wide
  _groupKey = <primitive>,
  _groupName = "battle",
  _count = <number>, -- count including this row within the window

  -- original schemas, enriched
  customers = {
    age = 42,
    _avg = {
      age = 37,
    },
    _sum = {
      age = 222,
    },
  },

  battle = {
    combat = {
      damage = 10,
      healing = { received = 5 },

      _sum = {
        damage = 81,
      },
      _avg = {
        damage = 13.5,
      },
    },
    healing = {
      _sum = {
        received = 124,
      },
    },
  },
}
```

Example (animal herd intuition):

```lua
Query.from(animals, "animals")
  :groupByEnrich(function(row)
    return row.animals.type -- "Elephant", "Zebra", ...
  end, { window = { time = 10, field = "sourceTime" } })
  :having(function(evt)
    -- only pass animals whose herd size has reached at least 5 in the last 10s
    return (evt._count or 0) >= 5
  end)
```

Here, the nth Zebra “knows” how many Zebras have appeared in its window so far. This is hard to
model with plain SQL but natural in a reactive, per-event pipeline.

**Design note:** enriched events are powerful for mod/game logic (“gate this event based on herd
size”), while pure aggregates are more natural for dashboards / metrics / further joins.

**Future intent:** we should aim for enriched events to be **re-usable as inputs to new queries**
where it makes sense. That likely means:

- treating `row` as a normal row view (or JoinResult) so it can feed directly into another
  `Query.from(...)` chain; and/or
- exposing aggregates via a consistent schema (e.g. attaching a dedicated `RxMeta.schema` for the
  aggregate view and using the `_sum` / `_avg` / `_min` / `_max` conventions) so grouped streams
  can be re-joined like any other source.

We do not lock this shape in yet, but grouping should not make re-use impossible.

---

## 6. What we do *not* copy from SQL

Classic SQL GROUP BY allows selecting non-aggregated columns; the engine then picks an arbitrary
member’s value (or relies on dialect-specific rules). This is confusing in a streaming context.

Our design aims to be explicit:

- Aggregate view:
  - Contains **only** group key + metrics + window metadata.
  - If you want a representative member (e.g. first/last), that should be an **explicit aggregator**
    (e.g. `first()`, `last()`, `maxBy`, etc.) rather than “magic” column behavior.
- Enriched event view:
  - Contains the full row view (all schema fields) and metrics for the group at that moment.
  - Per-event decisions should use this view instead of relying on “some random group member”.

This keeps semantics explainable and testable, especially under sliding windows.

---

## 7. API sketch (high-level, not final)

**Single grouping, aggregate view (fluent):**

```lua
local grouped =
  Query.from(customers, "customers")
    :leftJoin(orders, "orders")
    :onSchemas({ customers = "id", orders = "customerId" })
    :joinWindow({ time = 7, field = "sourceTime" }) -- regular join window
    :where(function(row)
      return row.customers.segment == "VIP"
    end)
    :groupBy(function(row)
      return row.customers.id
    end)
    :groupWindow({ time = 10, field = "sourceTime" })
    :aggregates({
      count = true, -- exposes _count (count per group)
      sum = { "customers.orders.amount" }, -- exposes customers.orders._sum.amount
      avg = { "customers.orders.amount" }, -- exposes customers.orders._avg.amount
    })
    :having(function(g)
      return (g._count or 0) >= 3
    end)
```

**Single grouping, enriched event view (fluent):**

```lua
local perEvent =
  Query.from(animals, "animals")
    :groupByEnrich(function(row)
      return row.animals.type
    end)
    :groupWindow({ time = 10, field = "sourceTime" })
    :aggregates({ count = true })
    :having(function(evt)
      return (evt._count or 0) >= 5
    end)
```

These sketches deliberately mirror the existing builder style (`from` → joins → `where` →
grouping → `having`/projection).

---

## 8. Open questions / places we need more clarity

Before hardening this into implementation, we should answer:
1. **Aggregate API (concrete v1 scope)**
   - We want to ship a **small but useful standard set** of aggregate functions:
     - `count` — number of events in the group window (exposed as `_count`);
     - `sum(field)` — sum over a numeric field;
     - `min(field)` / `max(field)` — extrema over a numeric field;
     - `avg(field)` — average, derived from `sum(field)/count`.
   - Configuration proposal:
     - Use an `aggregates` table in `groupBy` options, where aggregate kinds map to lists of field
       paths:
       ```lua
       aggregates = {
         count = true, -- optional flag, but _count is always present
         sum = { "battle.combat.damage", "battle.healing.received" },
         min = { "customers.age" },
         max = { "customers.age" },
         avg = { "battle.combat.damage" },
       }
       ```
     - Field paths are dotted strings including the schema name (e.g. `"battle.combat.damage"`)
       that map to nested tables under that schema in the payload, **mirroring intermediate tables
       from the row where possible**:
       - if `row.battle.combat` is a table and `row.battle.combat.damage` is numeric, we aggregate
         into `battle.combat._sum.damage`, `battle.combat._avg.damage`, etc.;
       - if the path does not exist yet under that schema in the aggregate payload, we create
         intermediate tables on demand so consumers can treat aggregates as a parallel tree of
         `_sum` / `_avg` / `_min` / `_max` tables.
   - Behavior notes:
     - `count` is computed **for every grouping**, regardless of whether `aggregates.count` is set;
       `_count` is always present in both aggregate and enriched views.
     - When the effective count for a given field is `0`, we report `avg` as `nil` for that field.

2. **Integration with existing `describe()` / plan inspection**
   - Grouping must appear in `Query.describe()` so users can inspect group keys, group window, view
     mode, and aggregate configuration.
   - Plan shape (conceptual):
     ```lua
     plan.group = {
       mode = "aggregate" or "enriched",
       key = "function", -- descriptive tag only; we do not serialize the function
       window = {
         mode = "time" or "count",
         time = <seconds>|nil,
         field = <string>|nil,
         count = <number>|nil,
       },
       aggregates = {
         -- full aggregate config as passed into :aggregates(...)
         count = true,
         sum = { "battle.combat.damage", "battle.healing.received" },
         min = { "customers.age" },
         max = { "customers.age" },
         avg = { "battle.combat.damage" },
       },
     }
     ```
   - We expose the **full aggregate configuration** (not just names) so tools and visualizations
     can remain in sync with the query definition.

3. **Backpressure / resource caps (future work)**
   - For v1 we **do not enforce hard caps** on:
     - number of active groups;
     - per-group memory usage.
   - We should, however, keep the implementation amenable to future limits and metrics if needed.

---

## 9. Next steps

Once we’ve answered the open questions above, the next concrete steps would be:

1. Lock in the **aggregate row** and **enriched event** shapes in a small data-model spec.
2. Draft a low-level `GroupObservable.createGroupObservable(rowStream, options)` that:
   - maintains per-key group state and sliding windows;
   - emits aggregate view + optional expiration side channel;
   - can be wrapped into enriched event view.
3. Extend the high-level `QueryBuilder` with:
   - `groupBy(keyFn, opts)` for aggregate view;
   - `groupByEnrich(keyFn, opts)` for enriched event view;
   - `having(predicate)` that runs over whichever view is currently in use;
   - integration with `describe()` so group config is observable.
4. Add unit tests mirroring the WHERE briefing style:
   - basic grouping;
   - sliding windows;
   - both aggregate and enriched event behavior;
   - interactions with existing joins and join windows.

Feedback that would be most helpful now:

- Which **use-cases** (from your Zomboid/modding scenarios) should we treat as must-have for v1?
- Do you want the **aggregate view** or the **enriched event view** to be the default return of
  `groupBy(...)`?
- How strict should we be about group key types and behavior when keys are missing/invalid?
