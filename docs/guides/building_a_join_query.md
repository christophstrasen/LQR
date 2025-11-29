# Building a Join Query

This guide walks through a complete, minimal LQR query example. It shows how we:

- define two schema‑tagged sources;
- join them by key with a join window;
- filter with `where`; and
- observe both joined rows and expirations.

If you want more background on records, schemas, and join windows, see the concept docs in `docs/concepts/`.

---

## 1. Define schema‑tagged sources

We start with two tables and wrap them with `LQR.Schema.observableFromTable`. In real code these would usually be event streams or subjects, but the shape is the same.

```lua
local LQR = require("LQR")
local Query = LQR.Query
local Schema = LQR.Schema

-- Customers: schema "customers", identified by id
local customers =
  Schema.observableFromTable("customers", {
    { id = 1, name = "Ada", segment = "VIP" },
    { id = 2, name = "Max", segment = "Standard" },
  }, "id")

-- Orders: schema "orders", identified by id and referencing customers via customerId
local orders =
  Schema.observableFromTable("orders", {
    { id = 10, customerId = 1, total = 50 },
    { id = 11, customerId = 1, total = 125 },
    { id = 12, customerId = 2, total = 40 },
  }, "id")
```

At this point:

- each emission from `customers` / `orders` is a record with `RxMeta.schema` and `RxMeta.id`;
- these streams are ready to participate in joins.

---

## 2. Build a left join with a join window

Next we create a `Query` that joins customers to orders by key, using a simple count‑based join window.

```lua
local joined =
  Query.from(customers, "customers")
    :leftJoin(orders, "orders")
    :on({ customers = "id", orders = "customerId" })
    :joinWindow({ count = 1000 })
```

This says:

- start from the `customers` stream (schema `"customers"`);
- left‑join the `orders` stream (schema `"orders"`);
- join customers and orders where `customers.id` equals `orders.customerId`;
- keep at most 1000 cached records per side in the join window.

The resulting stream emits `JoinResult`s where:

- `result:get("customers")` is always present; and
- `result:get("orders")` is either a record or `nil` depending on whether a matching order was in the window.

---

## 3. Add a row‑level filter with `where`

Now we keep only VIP customers that currently have at least one matching order row.

```lua
local filtered =
  joined
    :where(function(row)
      -- row.customers / row.orders are row‑view tables
      return row.customers.segment == "VIP"
         and row.orders.id ~= nil
    end)
```

Here `row` is the row view:

- `row.customers` — the customer record;
- `row.orders` — the order record, or `{}` when there is no order (fields then read as `nil`).

---

## 4. Subscribe to joined rows

Finally, we subscribe to the filtered query and print what we see.

```lua
filtered:subscribe(function(row)
  print(("[joined] customer=%s order=%s total=%s"):format(
    row.customers.name,
    tostring(row.orders.id),
    tostring(row.orders.total)
  ))
end)
```

This subscription only sees rows that passed the `where` predicate.

---

## 5. Observe expirations with `expired()`

In addition to the main joined stream, every query exposes an `expired()` observable so you can see what leaves join/distinct/group windows and why.

```lua
filtered:expired():subscribe(function(expiredRecord)
  print(("[expired] schema=%s key=%s reason=%s matched=%s"):format(
    tostring(expiredRecord.schema),
    tostring(expiredRecord.key),
    tostring(expiredRecord.reason),
    tostring(expiredRecord.matched)
  ))
end)
```

Key points:

- `expired()` is an observability stream, not a business stream.
- Records dropped by `where` still age out of join/distinct/group windows and will appear on `expired()` when their window closes.
- You can use this to answer questions like:
  - “Which customers never matched any orders within this window?” (`matched == false`);
  - “Is my join window too small or too large?” (inspect reasons and frequency).

---

## Recap

In this guide we:

- wrapped two tables as schema‑tagged sources;
- built a left join with an explicit join key and join window;
- filtered joined rows with a row‑view `where` predicate; and
- observed both the main stream and the `expired()` side channel.

From here you can extend the same pattern with:

- additional joins (e.g. shipments, refunds);
- grouping and `having` for aggregate‑level conditions; and
- `distinct` to de‑duplicate noisy streams before joining.

---

## 6. Combine with other Rx operators

After building a query, you can still use regular lua‑reactivex operators to work with the resulting observables:

- apply `:map`, `:filter`, `:buffer`, `:throttle`, etc. to the joined stream if you need additional post‑processing; or
- derive metrics and diagnostics from `expired()` (e.g. `:groupBy`, `:count`, `:scan`).

LQR is designed to sit on top of lua‑reactivex, not replace it. For the full set of Rx operators and patterns, see:

- the ReactiveX documentation: https://reactivex.io/
- the lua‑reactivex fork used by this project: https://github.com/christophstrasen/lua-reactivex/tree/master/doc
