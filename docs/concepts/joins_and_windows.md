# Joins and Join Windows

LQR’s core feature is **joining streaming records** from multiple observables. This page explains:

- how streaming joins differ from classic SQL joins;
- which join types the high‑level API exposes; and
- how **join windows** control memory and “how long records can wait for a partner”.

If you already read `records_and_schemas.md`, you know what records, schemas, and `JoinResult`s are. This page builds directly on that.

---

## Streaming joins vs. SQL joins

In SQL, a join:

- reads rows from (usually finite) tables;
- computes a result set once per query; and
- returns a snapshot.

In LQR:

- sources are **infinite streams of records** (Rx observables);
- joins run **continuously** as new records arrive;
- each match produces a `JoinResult` **immediately**; and
- records are only allowed to participate in joins while they are “warm” inside a **join window**.

That last part—join windows—is what caps memory and compute use and defines how long a record is allowed to wait for a matching partner before it is dropped.

---

## Join types (high level)

The high‑level builder supports several SQL‑like join types. Conceptually:

- `innerJoin` — emit only pairs where both sides have a match for the join key.
- `leftJoin` — emit all left records; attach right records when present, leave right as “missing” otherwise.
- `outerJoin` — emit records from both sides; where there is no partner, that side’s fields are “missing”.
- `anti*` joins — emit only records that **never** saw a partner on the other side within the join window:
  - `antiLeftJoin` — left records with no right partner;
  - `antiRightJoin` — right records with no left partner;
  - `antiOuterJoin` — unmatched records from both sides.

Example (customers ⟕ orders):

```lua
local joined =
  Query.from(customers, "customers")
    :leftJoin(orders, "orders")
    :on({ customers = "id", orders = "customerId" })
```

Subscribing to `joined` yields `JoinResult`s where:

- `result:get("customers")` is always present (left side of the left join);
- `result:get("orders")` is either a record or `nil`, depending on whether an order with a matching `customerId` arrived in time.

On the row view used by `where`, that becomes:

- `row.customers` — the customer record;
- `row.orders` — the order record, or an empty table `{}` when no partner was found.

### When results appear: matched vs unmatched

Not all join results have the same latency:

- **Matched rows** are emitted as soon as both sides have at least one record with the same join key in the window.  
  This is where `innerJoin` and the “matching part” of `leftJoin` / `outerJoin` stay low‑latency.

- **Unmatched rows** (left‑only / right‑only / anti‑joins) can only be emitted once LQR knows that a **specific record on one side** will never see a partner. that is usually determined when the record’s join window closes (it is evicted by count, expired by time, or dropped by a predicate).

In practice this means:

- `innerJoin` results are all “fast” (they are all matches);
- `leftJoin` / `outerJoin` emit matches quickly, but left‑only / right‑only rows only appear once that record’s join window closes;
- `anti*` joins emit **only after** each record’s join window closes, because they are defined in terms of “never matched”.

---

## Why join windows exist

Streams are unbounded; your process is not. Without limits, a join that keeps “all records ever seen” around, hoping for a late match, would:

- grow without bound in memory; and
- make it impossible to reason about how long a record is allowed to wait for a partner.

Join windows answer: **“For how long can a record stay join‑eligible?”**

LQR supports two main shapes:

1. **Count‑based windows** — limit how many entries the join cache can hold per side (across all keys).
2. **Time‑based (interval) windows** — limit how old a cached record may become.

In both cases, once a record falls out of the window, it is:

- removed from the internal cache; and
- reported on the `expired()` side channel with a `reason` (e.g. `evicted` or `expired_interval`).

---

## Count‑based join windows

A count window keeps at most N cached entries per join side, across all join keys.

Example:

```lua
local joined =
  Query.from(customers, "customers")
    :innerJoin(orders, "orders")
    :on({ customers = "id", orders = "customerId" })
    :joinWindow({ count = 1000 })
```

Here:

- each side keeps at most 1000 cached records across all keys;
- when a new record arrives and the window is “full”, the **oldest** record is evicted; and
- the evicted record appears on `joined:expired()` with `reason = "evicted"`.

Count windows are a good fit when:

- you mostly care about a **hard upper bound** on memory; and
- you don't have (or don't care about) a notion of event time in your records; and
- you don't want to or can't maintain a stable clock source.

Note:

- If you add a `:distinct` stage on the same key you use in `:on(...)`, the join will see at most one record per key for that schema during the distinct window. The count‑based join window still applies as an outer safety net on **total** cached entries per side.

---

## Time‑based (interval) join windows

An interval window keeps records **up to some age**, measured against a numeric timestamp field (usually event time).

Example (using `sourceTime` as the timestamp field):

```lua
local joined =
  Query.from(customers, "customers")
    :leftJoin(orders, "orders")
    :on({ customers = "id", orders = "customerId" })
    :joinWindow({
      time = 5,                     -- seconds
      field = "sourceTime",         -- optional: which field to read event time from (defaults to "sourceTime")
      currentFn = os.time,          -- optional: current clock function (defaults to os.time)
    })
```

Here:

- a customer stays eligible to match orders only while
  `currentFn() - customer.RxMeta.sourceTime <= 5`;
- once it becomes older than 5 seconds, it is expired:
  - for inner joins, it simply disappears from the cache and is reported on `expired()`;
  - for join types that surface unmatched rows (left/outer/anti joins), this is the moment where that record is treated as “no partner arrived in time” for that join

When you specify only `time` in `joinWindow({ time = ... })`, LQR assumes:

- `field = "sourceTime"` (it looks at `record.RxMeta.sourceTime` by default); and
- `currentFn = os.time`.

Interval windows are a good fit when:

- you think in terms of **freshness** (“events older than 3 seconds are no longer relevant”); and
- you want window behavior to be directly tied to event timestamps.
- you can accept that event spikes may grow cache and compute

## Controlling multiplicity: `oneShot` and `distinct`

Joins in LQR operate on **events in a window**, not on “one row per entity”. If both sides can emit several records per key while they are in the window, an `innerJoin` will match **every pair of records** with the same key that overlap in the join window.

For a single join key:

- 3 left‑side records
- 4 right‑side records
- all valid in the current window

Can produce up to **12** join results for that key!

> Even if “at the entity level” you think of it as a 1:1 relationship on `id`, it is not. **Observations of a thing are not the thing itself.**

And as all records truly match, this is the correct and bias‑free streaming behavior, but it often surprises first‑time users who expect “one joined row per id”.

LQR exposes two knobs that help you control this multiplicity:

### **Join‑side `oneShot`**
(via `on{ ..., oneShot = true }` on a given side)  

After a cached record on that side produces its **first** match on this join step, it is removed from that side’s cache. Later records with the same join key are still allowed in and may match against other cached records, but that particular cached entry will not be reused for further matches.  
This is about “each cached record is used at most once”, not about deduping the upstream schema.

> `oneShot` does not mean “only one match per key”; it means “this **record** has a single match ticket”:

- with `oneShot = true` on the **left** only, each left record is used at most once, but a right record can still match several different left records;
- with `oneShot = true` on the **right** only, the situation is symmetric;
- with `oneShot = true` on **both sides**, each record is used at most once, so the total number of matches per key is bounded by `min(#left events, #right events)` rather than `#left × #right`.

### **Schema‑level `distinct`**
(via `QueryBuilder:distinct(schema, opts)`)

Runs as a separate builder stage before/after joins and keeps at most one entry per key in its own cache, suppressing later events with the same key while that key is remembered. This is the right tool when you want to treat repeated observations of an entity as duplicates for a while. See `distinct_and_dedup.md` for details.

As a rule of thumb:

- use **`oneShot`** when you conceptually want “each cached record on this join side may participate in at most one match” (for example, lookups or dimension‑style joins that should not fan out indefinitely within the window);
- use **`distinct`** when you want **schema‑level deduplication** that applies across joins, `where`, and grouping, and you want to reduce noise from repeated observations before they even reach the join.

---

## Many records per key: per‑key buffers

This section is more advanced; you can ignore per‑key buffers for most basic queries. It matters when you consciously want “up to the last N observations per key” rather than “whatever happens to be in the global window”.

Even without multiplicity, real streams often have **many records per join key** from upstream sources (e.g. many orders per customer). LQR handles this by maintaining a small per‑key buffer rather than just the “latest value”.

At a high level:

- for each join side, you can configure how many records to keep **per join key** via `perKeyBufferSize` (through the `on{ ... }` options);
- each new record for a key is appended to that key’s buffer;
- if the buffer is full, the oldest record for that key is evicted and reported on `expired()` with `reason = "replaced"`.

This is independent of the global join window:

- the **per‑key buffer** controls how many recent observations per entity (per join key) you keep around for matching;
- the **join window** controls how many / how old in total records are allowed to stay join‑eligible.

One way to picture this:

- **Per‑key buffer = shelf per entity**  
  Imagine one shelf per customer (join key). Every time you see a new order for that customer, you put a box on their shelf. If the shelf only has 3 slots, the 4th box pushes the oldest one off.  
  → “How many recent observations of *this* entity do I keep?”

- **Join window = size of the whole warehouse**  
  Now imagine the fire code says the warehouse can only hold 1 000 boxes total. Even if each shelf is small, once the building is full you must start throwing out the oldest boxes, no matter which shelf they’re on.  
  → “How many observations across *all* entities can I keep around, and for how long, before I start throwing the oldest ones out?”

You do not need to configure this for basic usage, but it is useful when you want, for example, “up to the last 3 orders per customer” instead of “whatever happens to fit in the global window”.

---

## The `expired()` side channel

Joins keep short‑lived caches of records so they can find partners. The `expired()` side channel lets you **see what leaves those caches and why**. It is not a business stream; it is a diagnostics/observability stream that helps you understand and tune your join windows.

Every join builder exposes an `expired()` observable:

```lua
local query =
  Query.from(customers, "customers")
    :leftJoin(orders, "orders")
    :on({ customers = "id", orders = "customerId" })
    :joinWindow({ count = 1000 })

query:expired():subscribe(function(expiredRecord)
  print(("[expired] schema=%s key=%s reason=%s matched=%s"):format(
    tostring(expiredRecord.schema),
    tostring(expiredRecord.key),
    tostring(expiredRecord.reason),
    tostring(expiredRecord.matched)
  ))
end)
```

Each expired record tells you:

- `schema` — which schema it belonged to (`"customers"`, `"orders"`, …);
- `key` — the join key value (`joinKey`) used for that record on this join step;
- `reason` — why it expired (e.g. `evicted`, `expired_interval`, `completed`, `disposed`, `replaced`);
- `matched` — whether it ever matched at least once on this join step; and
- `result` — a `JoinResult` containing just that one schema’s record.

Typical uses:

- **“Which entities never matched?”**  
  Filter on `matched == false` and the appropriate `reason` to see records that aged out without ever finding a partner.

- **“Is my window too small or too large?”**  
  Inspect how often, and for which keys, records expire due to the window. If many “important” records expire unmatched, you may want to widen the window; if almost nothing expires and memory usage is high, you may want to narrow it.

In other words:

- the main joined stream is what your business logic consumes; and
- `expired()` is for understanding what left the join (or distinct/group windows) and why, so you can debug and tune behavior.

---

## Summary

Key ideas to carry forward:

- Streaming joins operate over **records in a join window**, not over entire tables.
- Join types (inner/left/outer/anti*) behave like their SQL cousins, but results are emitted continuously as events arrive.
- Join windows (count‑ or time‑based) define how long records remain eligible to match and keep memory bounded.
- Per‑key buffers let you keep a limited history per entity instead of just the latest value.
- The `expired()` side channel tells you when and why records leave join/distinct/group windows, and whether they ever found a partner.

With this mental model, later docs on `where`, grouping, `distinct`, and visualization will slot into place more easily.
