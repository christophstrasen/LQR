# Records and Schemas

LQR is built around **schema‑tagged records** flowing through ReactiveX observables. This page explains what “record” and “schema” mean in practice and how they show up in LQR queries.

If you understand this page, the later docs on joins, windows, and grouping will make much more sense.

---

## Records are events, not rows

In LQR, a **record** is a single emission on an Rx observable:

- It is just a Lua table.
- It always carries a `record.RxMeta` table with metadata.
- It represents something that happened, potentially *to* a more static entity, at a point in (event) time, .
- Rarely in business logic is the record the entity itself.

Typical source record (before any joins):

```lua
local record = {
  id = 1,
  name = "Ada",
  RxMeta = {
    shape = "record",
    schema = "customers",
    id = 1,
    idField = "id",
    sourceTime = 1710000000, -- optional
    schemaVersion = nil,     -- optional
  },
}
```

Key points:

- **`schema`** labels the logical type of the record (e.g. `"customers"`, `"orders"`).
- **`id`** is a stable identifier for that record within its schema.
- **`sourceTime`** (optional) is the event time used by time‑based windows and grouping.
- **`shape`** distinguishes source records (`"record"`) from join outputs and grouped views (described later).

You normally do not construct `RxMeta` by hand; you let `LQR.Schema` do it for you.

---

## Tagging sources with `LQR.Schema`

Before LQR can join or group your streams, each record must be tagged with a schema name and an id. `LQR.Schema` provides helpers for that.

### From a plain observable: `Schema.wrap`

If you already have an Rx observable of plain tables:

```lua
local LQR = require("LQR")
local Schema = LQR.Schema

local rawCustomers = rx.Observable.fromTable({
  { id = 1, name = "Ada" },
  { id = 2, name = "Max" },
}, ipairs, true)

-- Attach schema metadata; use the `id` field as identifier.
local customers =
  Schema.wrap("customers", rawCustomers, { idField = "id" })
```

After wrapping:

- every emission from `customers` is a record with a `RxMeta` table;
- `RxMeta.schema` is `"customers"`;
- `RxMeta.id` is taken from `record.id` (because we passed `idField = "id"`).

If you do not have a natural `id` field, you can supply an `idSelector` function instead of `idField` and generate a **synthetic, but stable** identifier, e.g. a UUID or an auto‑incrementing counter you maintain for that stream.

LQR does not *enforce* global uniqueness of `RxMeta.id`, but treating `id` as “this logical record’s identity” is strongly recommended:

- joins and grouping rely on join keys / group keys, not on `id`, so non‑unique ids will not break the core mechanics; but
- logs, metrics, visualization, and any dedupe logic that uses `id` as a key become much easier to reason about when each record for a given schema has a stable, unique id.

### From a Lua table: `Schema.observableFromTable`

For quick experiments and tests, you can build a schema‑tagged observable directly from a Lua table:

```lua
local customers = Schema.observableFromTable("customers", {
  { id = 1, name = "Ada" },
  { id = 2, name = "Max" },
}, "id") -- shorthand for { idField = "id" }
```

This is the helper used in the Quickstart example.

---

## Join outputs: `JoinResult`

Join steps do not emit raw records. Instead, they emit **`JoinResult`** containers that hold one or more schema‑tagged records.

For a simple customers ⟕ orders join:

```lua
local joined =
  Query.from(customers, "customers")
    :leftJoin(orders, "orders")
    :on({ customers = "id", orders = "customerId" })

joined:subscribe(function(result)
  local customer = result:get("customers")
  local order    = result:get("orders")

  -- ...
end)
```

Conceptually, each emission from `joined` looks like:

```lua
result = {
  customers = { id = 3, name = "Ada", RxMeta = { schema = "customers", id = 3, ... } },
  orders    = { id = 10, customerId = 3, total = 50, RxMeta = { schema = "orders", id = 10, ... } },
  RxMeta    = {
    shape = "join_result",
    schemaMap = {
      customers = { schema = "customers", joinKey = 3, sourceTime = 1710000000, ... },
      orders    = { schema = "orders",    joinKey = 3, sourceTime = 1710000001, ... },
    },
  },
}
```

You rarely need to touch `schemaMap` directly. The important bits for day‑to‑day use:

- `result:get("schemaName")` returns the record for that schema (or `nil`).
- `result:schemaNames()` returns a sorted list of schema names present in the result.

Note that `joinKey` is the **resolved key value** for that join step (e.g. `3` for `customers.id == 3`), not the name of the field. The join picks up this value from the `on{ ... }` configuration and stores it alongside each participating schema for observability and downstream helpers.

---

## Row view: what `where` and grouping see

To keep predicates simple, the high‑level API exposes a **row view** over each `JoinResult`. A row view is just a plain table:

```lua
row = {
  customers = { id = 3, name = "Ada", RxMeta = { ... } } or {},
  orders    = { id = 10, total = 50, RxMeta = { ... } } or {},

  _raw_result = result, -- the original JoinResult (escape hatch)
}
```

### How to think about the row view

When you write a query like:

- `Query.from(customers, "customers")`
- `:leftJoin(orders, "orders")`

LQR guarantees that every row you see in `where` has:

- `row.customers` — a table for the `"customers"` schema
- `row.orders`    — a table for the `"orders"` schema

with this behavior:

- If a schema has a matching record in the join, that table **is** the record:
  - `row.orders.id` is the joined order’s id.
- If a schema has **no** matching record (e.g. right side of a left join), that table is exists but is empty:
  - `row.orders.id` is simply `nil`.
- Hence, there is not need to defensively check if `row.orders` exists.

Normal Lua rules still apply:

- Row views only pre-populate schemas that appear in the query plan. Referencing an unknown schema (e.g. `row.foobar`) yields `nil`, and `row.foobar.id` will raise a regular “attempt to index a nil value” error.
- Schema names in `row.<schema>` come from your own labels. If you want to use dot syntax (`row.customers`), choose names that are valid Lua identifiers (e.g. `customers`, `orders`, `zombiesInRoom`). For other names (like `"order-items"`), use bracket syntax: `row["order-items"]`.

This is what `QueryBuilder:where(...)` receives:

```lua
Query.from(customers, "customers")
  :leftJoin(orders, "orders")
  :on({ customers = "id", orders = "customerId" })
  :joinWindow({ count = 1000 })
  :where(function(row)
    local c = row.customers
    local o = row.orders -- {} when no order

    -- keep only customers that have at least one order below 100
    return o.id ~= nil and (o.total or 0) < 100
  end)
```

Because missing schemas become empty tables, this works the same way for inner joins and outer joins.

---

## Why this matters

Everything else in LQR builds on top of these core ideas:

- joins operate on **schema‑tagged records** and emit `JoinResult` containers;
- filters (`where`) and grouping see **row views** derived from those results;
- windows, grouping, and `distinct` use metadata like `schema`, `id`, and `sourceTime` to make retention and aggregates predictable.

If you keep “records are events with schemas and IDs” in mind, the later docs on join windows, grouping, and expiration will read much more naturally.
