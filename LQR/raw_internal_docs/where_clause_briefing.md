# High-Level `WHERE` Semantics (Draft)

This document specifies the planned `WHERE`-style filtering surface for the
high-level query/join API built on top of Lua-ReactiveX. It is intentionally
small in scope: **no SQL parser, no AST builder**, just a clear, Rx-native,
post-join filter with a convenient row view.

The API design follows these principles:

- Operates **after joins**, on fully joined rows.
- Works for **inner and outer joins** without special cases.
- Uses plain Lua functions and tables (no metatables, no query DSL).
- Defaults are safe for reactive streams (no hidden backpressure changes).

---

## Goals

- Provide a fluent `WHERE`-like operation that:
  - filters **joined** results, not raw source rows.
  - supports **cross-schema predicates** (e.g. `orders.amount < customers.creditLine`).
  - behaves predictably with left/outer joins where one side may be missing.
- Keep the mental model close to relational SQL:
  - “FROM / JOIN / ON / WHERE / SELECT” ordering.
  - Missing side of a join behaves like `NULL` but in idiomatic Lua.
- Avoid the complexity and maintenance cost of:
  - string-based SQL parsers.
  - intermediate condition ASTs and custom evaluators.

---

## API Surface

### 1. Baseline: `QueryBuilder:where(predicate)`

**Signature (conceptual):**

```lua
-- Predicate receives either:
--   - the raw JoinResult, or
--   - a row view (see below) depending on the flavor we choose to expose.
---@param predicate fun(row:any):boolean
function QueryBuilder:where(predicate) -> QueryBuilder
```

**Fluent usage:**

```lua
local query =
  Query.from(customers, "customers")
    :leftJoin(orders, "orders")
    :using{ customers = "id", orders = "customerId" }
    :joinWindow{ time = 4, field = "sourceTime" }
    :where(function(row)
      -- example shown with the row view flavor
      local c = row.customers
      local o = row.orders

      -- treat missing schemas as empty tables (fields → nil)
      -- this is safe even for left/outer joins
      return (c.name or ""):match("^Max")
         and (o.amount or 0) < (c.creditLine or math.huge)
         or c.type == "VIP"
    end)
    :selectSchemas{ "customers", "orders" }
```

**Key properties:**

- `where` is **chainable** like other builder methods and returns a new
  `QueryBuilder`.
- Multiple `where` calls are not supported
- `where` is guaranteed to run **after all join steps** in the builder and
  **before** final `selectSchemas` projection.
- Under the hood it is equivalent to applying `:filter(predicate)` to the
  joined observable, but:
  - it is **attached to the builder**, not to the raw observable.
  - it participates in `describe()` / plan inspection.

### 2. Row View (Schema-Aware Helper)

To make predicates ergonomic and avoid repetitive `result:get(schema)` calls,
we expose a simple **row view** wrapper around each joined emission.

**Conceptual shape:**

```lua
row = {
  -- one field per schema name in the joined result
  customers = { ... } or {}, -- absent schema → empty table
  orders    = { ... } or {},
  refunds   = { ... } or {},

  -- optional access to the raw JoinResult if needed by power users:
  _raw_result = <JoinResult>,
}
```

**Design rules:**

- Each schema key (`row.customers`, `row.orders`, …) is always **present** and is
  always a **plain Lua table**.
  - If the schema is present in the `JoinResult`, it refers to the underlying
    record table.
  - If the schema is absent (e.g. right side of a left join with no match),
    it is an **empty table**.
- Accessing fields is always safe:
  - `row.orders.id` simply evaluates to `nil` when the `orders` schema is absent.
  - There is no need for metatables, `pcall`, or defensive `if row.orders then …`.
- The row view itself is a **plain table**:
  - no metatables.
  - no magic property lookup.
  - GC-friendly and easy to reason about.

**Example: left join with safe missing side**

```lua
-- Keep customers that either:
--   - are VIP, or
--   - have at least one order below their credit line.
local query =
  Query.from(customers, "customers")
    :leftJoin(orders, "orders")
    :using{ customers = "id", orders = "customerId" }
    :where(function(r)
      local c = r.customers
      local o = r.orders  -- {} when no matching order

      if c.type == "VIP" then
        return true
      end

      if not o.id then
        -- left-join row without a matching order
        return false
      end

      return (o.amount or 0) < (c.creditLine or math.huge)
    end)
    :selectSchemas{ "customers", "orders" }
```

Row view construction is an **implementation detail**, but the behavior above
is the contract.

## Execution Semantics

### 1. Position in the Pipeline

Logical order of operations for the high-level API:

1. `FROM` / root source(s) (via `Query.from(...)`).
2. Zero or more `JOIN` steps:
   - `innerJoin` / `leftJoin`, each with required `on` and optional `joinWindow`.
3. Zero or more `WHERE` steps:
   - `where(predicate)`; each filters joined rows.
4. Optional `SELECT`-style projection:
   - `selectSchemas{ ... }`.
5. Subscription:
   - `:subscribe(...)`, `:into(...)`, `:expired()`, visualization hooks, etc.

**Invariant:** Every `where` sees the **full join result** produced by all
preceding joins in the builder.

### 2. Streaming Behavior

- `where` behaves like a standard Rx `filter`:
  - emits only those joined rows for which `predicate(row)` is truthy.
  - completion and error signals are passed through unchanged.
- There is **no buffering** or reordering introduced by `where`.
- `joinWindow` and per-key buffers control **which events reach WHERE**; WHERE
  then acts purely as a **post-join gate**.

### 3. Join Type and Missing Schemas

- `WHERE` treats missing schemas as **present but empty** on the row view:
  - `r.orders` is `{}` when there is no matching `orders` record.
  - Individual fields you read from that table are simply `nil`.
- This is consistent across:
  - inner joins (typically both sides present, but not guaranteed if upstream
    sources misbehave).
  - left / outer joins (left side guaranteed, right side may be empty).
- It is entirely up to the predicate to decide how to handle missing data:
  - you can emulate SQL’s behavior (“WHERE drops rows with NULLs in certain
    expressions”) by checking for `nil`.
  - or you can treat missing partners as special values (e.g. “no orders
    counts as safe”).

---

## Non-Goals / Explicitly Out of Scope

- No free-form SQL parsing:
  - We will **not** support `:where("customers.name LIKE 'Max%' AND ...")`.
- No intermediate condition AST / micro-language:
  - We will **not** ship a `whereExpr():eq(...):andLessThan(...):toPredicate()`-style builder for now.
  - All conditions are plain Lua expressions inside a predicate function.
- No metatable magic:
  - The row view is a plain table; behavior is explicit and transparent.

These constraints keep the feature easy to reason about and cheap to maintain
while still covering the vast majority of realistic use cases.

---

## Key Principles (Summary)

- **Post-join filtering**  
  `where` always runs after the join pipeline; predicates see joined rows, not
  raw source events.

- **Schema-aware but simple**  
  The row view exposes schemas as named fields (`row.customers`, `row.orders`)
  using plain tables, with missing schemas represented as empty tables.

- **Outer-join friendly**  
  Missing partners never cause runtime errors; predicates choose how to treat
  absent data.

- **Rx-native semantics**  
  `where` is logically just a `filter` on the joined observable; no extra
  buffering or ordering semantics are introduced.

- **No DSL, no parser**  
  All conditions live in Lua predicates; no string-based SQL or AST builders.

This briefing should be treated as the reference for implementing and testing
the high-level `WHERE` support in the query builder and for writing user-facing
documentation and examples that use it.

---

# Implementation

### Decisions (locked in)
- Single `where` per builder chain (multiple calls are not supported).
- Row view only; `_raw_result` is the sole escape hatch to the underlying `JoinResult`.
- Describe surface: at most a boolean marker for presence of WHERE; no predicate serialization.
- Selection-only queries also support `where`.
- Row view builder should be reusable later (e.g., for a potential `HAVING`), so keep it factored.

### Phases and steps
**Phase 1 — Low-level (no changes expected)**
- Leave `JoinObservable` unchanged; WHERE is a high-level filter over joined `JoinResult`s.

**Phase 2 — High-level builder**
- Add builder state for a single predicate (e.g., `_wherePredicate`); guard against multiple `where` calls with a clear error.
- Implement `QueryBuilder:where(predicate)`:
  - validate predicate is a function;
  - clone builder, store predicate.
- Add a row-view constructor (plain function, no metatables) reusable later:
  - inputs: `JoinResult`, `schemaNames` to expose;
  - output: table with `row[schema] = result:get(schema) or {}` for each schema;
  - include `row._raw_result = result`.
- In `_build`:
  - after all joins, before `selectSchemas`, map each emission to the row view and apply `filter(predicate)`;
  - if no predicate, skip;
  - do not alter the `expired` side channel (WHERE filters only the main stream).
- Ensure selection-only flows work: row view should still be constructed over the single schema and filtering applied.

**Phase 3 — Describe/plan**
- Add a simple marker (e.g., `plan.where = true`) to `describe()` when a predicate is configured; do not serialize the function.

**Phase 4 — Tests**
- Add a new spec (e.g., `tests/unit/query_where_spec.lua`):
  - inner join happy path: predicate keeps expected matches;
  - left join: missing right side yields `{}` and predicate can safely read `row.orders.id`;
  - selection-only query with `where` filters root stream;
  - multiple `where` calls raise;
  - row view fields are plain tables, missing schemas are `{}`, and `_raw_result` is present;
  - ensure `selectSchemas` still projects after WHERE.

**Phase 5 — Examples (optional but recommended)**
- Add a short example in `examples` or `experiments` demonstrating `where` with row view and a left join.
