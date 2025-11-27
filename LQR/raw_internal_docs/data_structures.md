# Data Structures: Inputs, Joins, and Grouping Views

This note captures the exact shapes we feed into the query system and the structures that come out of joins and grouping (aggregate view and enriched event view). All examples are simple and schema-tagged.

**RxMeta.shape values:**
- `record` — plain schema-tagged source emissions
- `join_result` — join outputs (multi-schema container)
- `group_enriched` — grouped per-event view
- `group_aggregate` — grouped aggregate view

## 1) Inputs: schema-tagged records

- Create sources with `SchemaHelpers.subjectWithSchema(schemaName, opts?)` → returns `subject, observable`.
- `Schema.wrap` (used inside the helper) enforces/attaches `record.RxMeta`.
- `RxMeta` after wrapping:
  - `shape = "record"`
  - `schema` (string, required)
  - `id` (required: from `RxMeta.id` or `opts.idField`/`idSelector` or `record.id`)
  - `idField` label (derived from the chosen id source)
  - optional `schemaVersion`
  - optional `sourceTime`
  - `joinKey` is added later by joins

Example emission into a wrapped source:

```lua
customersSubject:onNext({ id = 1, name = "Ada" })
-- becomes:
-- { id=1, name="Ada", RxMeta={ schema="customers", id=1, idField="id" } }
```

## 2) Join output: JoinResult (plus row view helper)

Subscribers to joins receive `JoinResult` objects: a table keyed by schema name, plus `RxMeta.schemaMap` that tracks per-schema metadata.

Example (customers ⟕ orders on id=customerId):

```lua
result = {
  customers = { id=1, name="Ada", RxMeta={ schema="customers", id=1, sourceTime=10 } },
  orders    = { id=101, customerId=1, total=50, RxMeta={ schema="orders", id=101, sourceTime=11 } },
  RxMeta    = {
    shape = "join_result",
    schemaMap = {
      customers = { schema="customers", schemaVersion=nil, sourceTime=10, joinKey=1 },
      orders    = { schema="orders",    schemaVersion=nil, sourceTime=11, joinKey=1 },
    },
  },
}
```

Helpers:

- `result:get("orders")` → payload for that schema.
- `result:schemaNames()` → sorted array of schema labels.
- `JoinResult.selectSchemas(result, { "customers" })` → projection/rename tool for downstream joins.

Row view (what `where`/grouping see): a plain table with one field per schema (or `{}` if absent) plus `_raw_result` pointing back to the `JoinResult`.

```lua
row = {
  customers = { id=1, name="Ada", RxMeta=... },
  orders    = { id=101, total=50, RxMeta=... },
  _raw_result = result,
}
```

## 3) GroupBy Aggregate view (group state stream)

`groupBy` produces one synthetic record per group/window update. It is a **single-schema record** whose schema name is `groupName`, i.e. `g.RxMeta.schema = groupName` (default `_groupBy:<firstSchema>`), but its payload can contain aggregates for multiple upstream schemas under their own keys (e.g. `g.customers`, `g.orders`, `g.refunds`).

Shape:
- `_count` — events in the group window
- `_group_key` — mirrors the grouping key for easy display
- Per-schema aggregate trees with `_sum` / `_avg` / `_min` / `_max`
- `window = { start, end }` — event-time boundaries
- optional `_raw_state` for engine internals
- Grouping metadata lives in `RxMeta`:
  - `RxMeta.shape = "group_aggregate"`
  - `RxMeta.groupKey`, `RxMeta.groupName`, `RxMeta.view = "aggregate"`, `RxMeta.schema = groupName`

Example (groupName `"customers_grouped"`, key by customer id, sum+avg of `orders.total` and `refunds.amount`):

```lua
g = {
  _count = 3,
  orders = {
    _sum = { total = 150 },
    _avg = { total = 50 },
  },
  refunds = {
    _sum = { amount = 30 },
    _avg = { amount = 15 },
  },
  window = { start = 100, end = 110 },
  RxMeta = {
    schema = "customers_grouped",
    groupKey = 1,
    groupName = "customers_grouped",
    view = "aggregate",
    shape = "group_aggregate",
  },
}
-- emitted each time the group window changes (insert/evict)
```

Notes:
- `_count` is always present; other aggregates appear only if requested via `:aggregates`.
- Aggregates mirror the payload tree per schema: e.g. a field path `orders.total` ends up at `g.orders._sum.total`.

## 4) GroupBy Enriched event view (per-event with group context)

`groupByEnrich` keeps the joined row view and overlays live group metrics.

Shape:
- `_count` on the enriched row
- `_group_key` on the enriched row (the grouping key)
- Each schema table gains `_sum` / `_avg` / `_min` / `_max` mirrors for configured fields
- Grouping metadata lives in `RxMeta` (`shape = "group_enriched"`, `groupKey`, `groupName`, `view = "enriched"`)
- Optional synthetic grouping schema `_groupBy:<groupName>` containing aggregates + its own `RxMeta`

Example (grouping animals by `type`, count + weight aggregates):

```lua
enriched = {
  _count = 5, -- herd size in window
  RxMeta = {
    schema = "_groupBy:animals",
    groupKey = "Zebra",
    groupName = "animals",
    view = "enriched",
    shape = "group_enriched",
  },

  animals = {
    id = 42,
    type = "Zebra",
    weight = 180,
    _sum = { weight = 880 }, -- sums across Zebras in window
    _avg = { weight = 176 },
    RxMeta = { schema="animals", id=42 },
  },

  ["_groupBy:animals"] = { -- synthetic grouping schema (optional)
    _count = 5,
    _sum = { weight = 880 },
    _avg = { weight = 176 },
    RxMeta = {
      schema = "_groupBy:animals",
      groupKey = "Zebra",
      groupName = "animals",
      view = "enriched",
      shape = "group_enriched",
    },
  },
}
-- every incoming Zebra event is emitted with this enriched context after update
```

Notes:
- Original per-schema payloads remain intact; aggregates live in `_sum`/`_avg` (etc.) subtables.
- The synthetic grouping schema makes enriched streams easy to join downstream as a single schema.
