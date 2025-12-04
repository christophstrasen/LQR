# Grouping and `having`

Joins and `where` give you row‑level filters: “does *this* joined row match my condition?”. Other concerns that go beyond these capabilities could be:

- “How many orders has this customer had in the last minute?”
- “Only emit customers once they have at least 3 recent orders.”
- “Among the last 5 customers, who made the largest order?”
- “I want to see the metrics of my observation over a sliding window.”

For that, LQR provides **grouping** (streaming `GROUP BY`) and **`having`** (conditions over grouped state).

---

## Where grouping fits in the pipeline

Within a `Query` builder chain, grouping runs **after** joins and `where`, **before** final projection/subscription and it always sees the row view you know from `where` (`row.customers`, `row.orders`, …).

LQR's groupBy Observable introduces:

- `groupBy` / `groupByEnrich` — choose between aggregate view or enriched event view
- `groupWindow` — defines which rows belong to each group
- `aggregates` — selects which metrics to compute
- `having` — filters grouped results using aggregate values

---

## Example grouped query

`groupBy` collapses many rows per key into **one grouped row per key**, updated as new events enter or leave the group window. Here is a complete example to anchor the concepts:

Example: “VIP customers, grouped by customer id, with order count and total over the last 10 rows”:

```lua
local grouped =
  Query.from(customers, "customers")
    :leftJoin(orders, "orders")
    :using({ customers = "id", orders = "customerId" })
    :joinWindow({ count = 1000 })
    :where(function(row)
      return row.customers.segment == "VIP"
    end)
    :groupByEnrich("customers_grouped", function(row)
      return row.customers.id  -- group key
    end)
    :groupWindow({ count = 10 })  -- last 10 joined rows per customer
    :aggregates({
      sum = { "orders.total" },   -- sum over orders.total
    })
```

Subscribing to `grouped` yields one row per customer id, **whenever that customer’s group window changes**. In other words, you are observing the evolving state of each group over time, not taking a single static snapshot.

You can think of `groupByEnrich` + `aggregates` as “a streaming table of group metrics”, and `having` as “conditions over that table”.

From this grouped stream, LQR exposes two views over grouped state:

- an **enriched event view** with `groupByEnrich`, which keeps individual rows and overlays group aggregate values; and
- an **aggregate view** with `groupBy`, which emits one grouped row per key (as shown in the example above).

More on these views further below.

### The group key function

The function you pass to `groupBy` / `groupByEnrich` decides **which rows belong to the same group**:

```lua
:groupBy("customers_grouped", function(row)
  return row.customers.id  -- all rows with the same id share a group
end)
```

From the user’s point of view:

- Input: the same row view that `where` sees (`row.customers`, `row.orders`, …).
- Output: a **group key** that identifies “the entity” you want to group by, typically a customer id, room id, zone name, etc.

A few guidelines:

- Return a simple, stable key per group you wish to define:
  - primitives like strings/numbers/booleans work best (e.g. `row.customers.id`, `row.room.name`).
  - You can also use compound keys, for example `row.customers.lastName .. ":" .. row.customers.birthdate`.
  - rows with the same key end up in the same group window.
- Keep the function pure and cheap:
  - no side‑effects;
  - deterministic for the same row;
  - avoid blocking I/O.
- If the function returns `nil` or throws a Lua error (for example via `error(...)`), that row is **skipped for grouping** (no grouped emission is produced for that row, and a warning is logged).

---

## Choosing a view: `groupByEnrich` vs `groupBy`

### Behavior & emission timing

Internally, grouping behaves the same for both views:

- whenever a row for a key enters or leaves the group window:
  - aggregates for that key are recomputed; and
  - a new grouped emission is produced for that key.

There is no batching; both views are “update on every change”. In terms of **frequency**, groupByEnrich vs groupBy is roughly the same: one emission per insert/eviction per key. The difference is *what* you get in each emission.
Each emission represents the **current state of that group at that moment**; you are observing how the group evolves as rows enter and leave the window.

### Enriched view (`groupByEnrich`) — recommended default

Pros:

- Keeps the full row view (`row.customers`, `row.orders`, …) **plus** aggregate values:
  - `_count_all`, per‑field `_sum`, `_avg`, etc.
- Very natural for **per‑event decisions with context**, for example:
  - “let this zombie event through only once the room has at least 5 zombies in the last 10 seconds”;
  - “add a flag when this customer’s recent order total crosses a threshold”.
- Easy to debug and log; you still see all schema fields alongside the group’s state.
- `having` can look at both aggregate values **and** the original row fields in one place, so it can act as a final filter that combines group state and per‑event data.
- Can be reused as input to further joins or groupings if needed.

> **Why enriched + `having` is powerful**  
> In the enriched view, `having` sees both the original row fields (`row.customers`, `row.orders`, …) **and** the aggregate values (`row._count_all`, `row.orders._sum.total`, …). A single `having` predicate can therefore act as a final filter over **both** per‑event data and group state.

Cons:

- Payloads are larger (full row + aggregates).
- If you truly do not care about individual events, you are carrying more data than necessary.

> “If you’re making per‑event decisions that depend on group context, prefer
> groupByEnrich so each row carries both its original fields and the live group aggregate value.”

### Aggregate view (`groupBy`) — state stream

Pros:

- Conceptually close to SQL `GROUP BY`: one row per group key, representing current state.
- Payload is focused on aggregates:
  - group key, counts, sums/averages, window metadata.
- Good for:
  - dashboards / metrics streams;
  - joining aggregated state into other queries (e.g. a per‑customer risk score stream).

Cons:

- You lose easy access to the original per‑row fields (unless you explicitly carry them into the aggregate schema).
- Not ideal when you want to act on each original event; you end up translating group state back into row decisions yourself.

> “Use groupBy when you want a stream of group state (one row per key) and don’t need every original event in your downstream logic.”

### Rule of thumb

- Start with **`groupByEnrich`** when you care about individual events but need group context
- Reach for **`groupBy`** when you explicitly want a per‑key state stream (metrics, dashboards, or feeding aggregated state into other queries) and do not need every original row in downstream logic.

---

## Accessing aggregate values

Both views expose aggregate values in the same shape; the only difference is whether you read them off a **grouped row** from `groupBy` or an **enriched row** from `groupByEnrich`. In the examples below we will call this grouped state `groupResult`; in the enriched view, `groupResult` is simply the `row` you receive in `having` or downstream operators.

- **Row count per group*** (always on by default) 
  `groupResult._count_all` — number of rows in the group window for this key (`COUNT(*)`‑style).

- **count per schema** (always on by default)  
  `groupResult._count.orders` — how many rows in the group window contain an `"orders"` record;

> `_count_all` and `_count.<schema>` are enabled by default. Turn both off with `aggregates = { row_count = false }` if you do not need any counts.



- **Sum / average / min / max per field**  
  With:
  
  ```lua
  :aggregates({
    sum = { "orders.total" },
    avg = { "orders.total" },
    min = { "orders.total" },
    max = { "orders.total" },
  })
  ```
  
  you can read:
  
  - `groupResult.orders._sum.total` — sum of `orders.total` over the rows in the group window;  
  - `groupResult.orders._avg.total` — corresponding average (or `nil` when there are no samples);  
  - `groupResult.orders._min.total` / `groupResult.orders._max.total` — minimum / maximum `orders.total` in the window.

These Aggregates only appear for paths you request via `:aggregates`; `_count_all` / `_count` are controlled by the `row_count` knob (on by default).

In the aggregate view, `groupResult` is the grouped row you get from `result:get(groupName)`. In the enriched view, `groupResult` is simply `row` itself; enriched rows still expose the original row view (`row.customers`, `row.orders`, …), so you can combine per‑event fields and aggregate values in the same predicate or downstream logic.

---

## Group windows vs join windows

Grouping has its **own** window, separate from the join window:

- **Join window** (`joinWindow`) controls how long source records stay eligible to match in joins.
- **Group window** (`groupWindow`) controls over which slice of time/rows you compute aggregates.

You can, for example:

- keep a short join window (e.g. `{ time = 5 }`) to keep memory bounded for matching; and
- use a longer group window (e.g. `{ count = 50 }`) to compute aggregates over the last 50 joined rows per customer.

They are independent knobs.

Group windows are **per‑key sliding windows**:

- count windows keep the last `N` rows per key;
- time windows keep rows whose timestamp is within the last `T` seconds per key.

There are no built‑in fixed/tumbling time buckets; grouped rows are updated continuously as each key’s window slides.

---

## Using `having`

`having` is a filter applied **after** grouping. It works like `where`, but over grouped state instead of individual joined rows:

- in the aggregate view, your predicate receives the grouped row (our `groupResult`/`g`);
- in the enriched view, it receives the enriched row (`row`) with inline aggregates **and** the original row fields.

Typical uses:

- “only emit the state of groups with at least 3 rows in the window” → `return (groupResult._count_all or 0) >= 3`;
- “only emit the state of groups whose sum/avg crosses a threshold” → check fields like `groupResult.orders._sum.total` or `groupResult.orders._avg.total`;
- “only let enriched rows through where a row‑level condition and a group condition hold” → e.g. VIP customers **and** `(groupResult._count_all or 0) >= 3` in the last 10 seconds.

> As in the enriched view `having` can access the full `row` (which is also your `groupResult`), it can serve both as aggregate filter _and_ as final filter stage to apply row‑level conditions but now with full group context.

`having` does not change group windows; it simply decides which grouped emissions are visible downstream.

---

## `where` vs `having`

It helps to keep a simple rule of thumb:

- Use **`where`** for **row‑level** decisions:
  - Conditions that look at a single joined row (`row.customers`, `row.orders`) and decide whether that row should pass.
- Use **`having`** for **group‑level** decisions:
  - Conditions that look at grouped state (`g._count_all`, sums, averages) and decide whether a group (or group‑enriched row) should pass.

Grouping operators keep the streaming nature of the system: grouped rows are updated as the window slides, and `having` filters those updates in real time.
In other words, `where` decides which individual joined rows enter grouping in the first place, while `having` decides which group state updates are allowed downstream.

---

> **Advanced knobs (beyond this doc)**  
> Group windows are always per‑key sliding windows, but you can refine what they see:
>
> - by choosing a meaningful group key (e.g. group by customer id vs room id vs a composite key);
> - by using `distinct` or aggregate‑level `distinctFn` to count distinct entities instead of raw rows;
> - by applying upstream filters so only certain rows ever enter the grouping window.
>
> These do not change the sliding nature of the window, but they change **what** is counted inside it.
