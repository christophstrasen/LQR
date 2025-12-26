# Row‑Level Filtering with `where`

Once you have a joined stream, you usually want to keep only the rows that matter. In LQR you do this with `where`, which behaves like a SQL `WHERE` clause but in plain Lua.

---

## Where `where` sits in the pipeline

Within a single `Query` builder chain, `where` runs **after** any joins that come before it in the chain, and **before** later steps such as grouping, projection, or subscription. You can also use `where` on selection‑only queries (no joins at all).

`where` always sees the joined row produced by the steps before it and behaves like a simple filter: for each row, your predicate decides “keep or drop?”. It does not reorder or buffer records; join windows and per‑key buffers still decide which records can reach `where` in the first place.

---

## The row view in practice

To keep predicates readable, the high‑level API exposes each joined emission as a **row view**:

```lua
row = {
  customers = { id = 1, name = "Ada", RxMeta = { ... } } or {},
  orders    = { id = 10, total = 50, RxMeta = { ... } } or {},
}
```

Think of `row` as “one table per schema in the query”, with missing partners represented as empty tables. The full row view also carries `_raw_result` with the underlying `JoinResult` as described in [records_and_schemas](records_and_schemas.md); in this concept we focus on the per‑schema tables you normally use in `where` predicates.

---

## Examples

### Left join with a missing right side

```lua
local query =
  Query.from(customers, "customers")
    :leftJoin(orders, "orders")
    :using({ customers = "id", orders = "customerId" })
    :joinWindow({ count = 1000 })
    :where(function(row)
      -- keep VIP customers that currently have a matching order row
      return row.customers.segment == "VIP"
         and row.orders.id ~= nil
    end)
```

Because `row.orders` is always a table, you can safely write `row.orders.id` without extra guards; missing partners simply show up as `nil` fields.

---

## How `where` behaves in a streaming join

From a streaming perspective, `where` is deliberately simple. Conceptually it is the Rx `filter` operator applied to the joined stream, but with LQR‑specific advantage of works on the row view, and is guaranteed to sit in the right place relative to joins and grouping.

- It does **not** change join windows or per‑key buffers.
- For each incoming row:
  - if `predicate(row)` is truthy, the row passes through;
  - otherwise it is dropped.
- Completion and errors flow through as they would for a normal Rx `filter`.

In practice:

- Tune **join windows** and **per‑key buffers** to control “what can reach where”.
- Use `where` to express “of those rows, which ones do I actually care about?”.
- The `expired()` side channel is unaffected: records dropped by `where` still age out of join/distinct/group windows as usual and will appear on `query:expired()` when their window closes.

---

## Writing good predicates

A few guidelines for `where` predicates:

- **Think SQL `WHERE`, but in Lua.**  
  Combine schema fields freely, e.g. `o.total < c.creditLine`, `zombies.count > rooms.capacity`, etc.

- **Be explicit about missing partners.**  
  Decide what “no order” or “no zombie in this room” means for your logic (drop the row, or treat it as safe).

- **Keep `where` for row‑level logic, not aggregates.**  
  `where` sees individual joined rows, not grouped aggregates. If you want to filter based on counts or sums over a group (“at least 3 orders in the last minute”), use `groupBy` / `groupByEnrich` plus `having` in the grouping stage, not `where`.

- **Keep them cheap and side‑effect light.**  
  Predicates run once per row in the stream; avoid blocking I/O or heavy work inside them.

With this mental model, `where` stays close to its SQL cousin while remaining a predictable, streaming‑friendly filter over joined rows.

---

## Filtering at the end: `finalWhere`

`finalWhere(fn)` filters the **final** values that a normal subscriber would see.

Compared to `where`:

- `where` runs **before** `selectSchemas` and before grouping. It evaluates the **row view** and is intentionally limited to a single call.
- `finalWhere` runs **at the end** of the query pipeline (after joins, `where`, selection, and after `groupBy`/`having` when present). It evaluates the **final emission value** and can be called multiple times.

Use `finalWhere` when you want a clean “consumer‑side filter” that stays stable even as you add joins, selection aliases, grouping, or `having`.

Example:

```lua
local query = Query.from(customers, "customers")
  :selectSchemas({ customers = "customer" })
  :finalWhere(function(result)
    return result.customer.segment == "VIP"
  end)
```

---

## Instrumentation: `finalTap`

`finalTap(fn)` attaches a small “final emission hook” to a `Query` builder: `fn` is called for every value that would reach a normal subscriber. It runs at the **end** of the query pipeline (after joins, `where`, selection, `finalWhere`, and also after `groupBy`/`having` when those are present).

You can attach multiple final taps by calling `finalTap(...)` multiple times; they run in call order.

Use it for debugging/metrics (“what does my query *actually* emit?”) without having to drop out of the fluent `Query` builder into raw Rx plumbing. Unlike calling `:tap(...)` on an Observable, `finalTap` has a stable, query‑level placement and won’t accidentally observe intermediate streams before `where`/grouping.

Example:

```lua
local query = Query.from(customers, "customers")
  :leftJoin(orders, "orders")
  :using({ customers = "id", orders = "customerId" })
  :where(function(row)
    return row.customers.segment == "VIP"
  end)
  :finalTap(function(result)
    -- `result` is the final emission value (for join/selection queries this is a JoinResult).
    print("final customer id", result:get("customers").id)
  end)
```
