# LQR – Lua integrated Query over ReactiveX

*A Lua library for expressing SQL‑like joins and queries over ReactiveX observable streams.*

[![CI](https://github.com/christophstrasen/Lua-ReactiveX-exploration/actions/workflows/ci.yml/badge.svg)](https://github.com/christophstrasen/Lua-ReactiveX-exploration/actions/workflows/ci.yml)

LQR (pronunced like "LiQoR", /ˈlɪk.ər/) sits on top of [lua‑reactivex](https://github.com/christophstrasen/lua-reactivex) and adds a schema‑aware query layer:

- streaming joins (`inner`, `left`, `outer`, `anti*`) with explicit join windows and per‑key buffers;
- `WHERE`-style filtering over joined rows;
- `GROUP BY` / `HAVING` over sliding windows with aggregates;
- per‑schema `distinct` 
- expiration / observability streams;
- optional visualization adapters for showcasing or inspecting specific join behavior.

It is designed for in‑process, single‑threaded environments like Lua game runtimes, but works in any Lua 5.1 host that can run lua‑reactivex. Its mental model is “embedded stream processing,” borrowing ideas from Flink/Spark without aiming for their distributed guarantees. Like ReactiveX itself, LiQoR stays local: no clustering, checkpointing, or durability—it’s compositional stream processing inside your Lua app.

---

https://github.com/user-attachments/assets/42733f4d-7063-4cf2-9047-0f6ada5b4172

---

## Dependency: lua-reactivex

LQR does not vendor lua-reactivex. Check out **our fork** into `./reactivex` (sibling to `./LQR`) so `require("reactivex.*")` resolves for examples, tests, and the viz pipeline:

- `git clone https://github.com/christophstrasen/lua-reactivex.git reactivex`  
  or `git submodule add https://github.com/christophstrasen/lua-reactivex.git reactivex && git submodule update --init --recursive`
- Legacy fallback: a sibling checkout at `../lua-reactivex` is still discovered by `LQR.bootstrap`, but the root-level `./reactivex` path is the default.

---

## Quickstart

This example shows how to:

- wrap two in‑memory tables as schema‑tagged observables;
- join them by key with a simple count‑based join window;
- filter joined rows with a `WHERE`‑style predicate; and
- subscribe to both the joined stream and the expiration side channel.

```lua
local LQR = require("LQR")

local Query = LQR.Query
local Schema = LQR.Schema

-- 1) Wrap tables into schema-tagged observables.
local customers = Schema.observableFromTable("customers", {
  { id = 1, name = "Ada" },
  { id = 2, name = "Max" },
}, "id")

local orders = Schema.observableFromTable("orders", {
  { id = 10, customerId = 1, total = 50 },
  { id = 11, customerId = 1, total = 75 },
}, "id")

-- 2) Build a streaming left join: customers ⟕ orders USING id/customerId.
local query =
  Query.from(customers, "customers")
    :leftJoin(orders, "orders")
    :using({ customers = "id", orders = "customerId" })
    :joinWindow({ count = 1000 }) -- simple bounded cache per side
    :where(function(row)
      -- keep only customers that have at least one order
      return row.orders.id ~= nil
    end)

-- 3) Consume joined results.
query:subscribe(function(result)
  local customer = result:get("customers")
  local order = result:get("orders") -- may be nil for unmatched left rows

  print(("[joined] customer=%s order=%s total=%s"):format(
    customer and customer.name or "nil",
    order and order.id or "none",
    order and order.total or "n/a"
  ))
end)

-- 4) Observe expirations: when records leave the join window or expire for other reasons. Useful for debugging and query/cache optimization
query:expired():subscribe(function(packet)
  print(("[expired] schema=%s key=%s reason=%s"):format(
    tostring(packet.schema),
    tostring(packet.key),
    tostring(packet.reason)
  ))
end)
```

In a real project you would typically:

- build observables from event buses or subjects instead of static tables; and
- layer additional operators like more complex `:where(...)` predicates, `:groupBy(...)`, and `:distinct(...)` on top of the join.

See [examples.lua](examples.lua), [tests/unit](tests/unit), and [vizualisation/demo](vizualisation/demo) for more varied scenarios.

---

## When would you want to use LQR or reactive programming?

Reach for the L*i*Q*o*R when you need to relate and group several event sources in real time; use plain reactive streams for simpler live work, and if polling already gives timely answers in a simple enough manner, you don’t need to "go reactive" at all.

### What LQR gives you over bare event handlers, loops, and ad‑hoc queries

- Queries that stay mounted and update incrementally
- Per‑key state that manages itself
- Many views over the same events
- Time is a first class concept
- One place for cross‑stream domain logic
- Helps avoid overload and spikes
- Handles late, missing, and out‑of‑order events

See [advantages](docs/guides/advantages.md) for the details.

### Choosing between polling, plain Rx, and LQR

**In a nutshell:**

1) **Skip reactive programming when:**
- You can poll or call when needed and still meet latency requirements
- correctness/completeness matters more than immediacy
- You need strict ordering or transactions 
1) **Use Plain Rx when:**
- You can’t pull all data in one go
- You’re following/observing a single stream/thing
- You're handling primarily scalars/simple values
- “live enough” matters more than full completeness
1) **Try out LQR when:** 
- You can’t pull all data in one go
- You need to relate multiple streams/observations
- You need to support more complex shapes and different data rates
- You don't need to create a perfectly complete snapshot. 

### Tradeoffs at a glance

Quick comparison of what each approach may deliver

| Concern           | Non-reactive (poll) | Plain Rx | LQR      |
| ----------------- | ------------------- | -------- | -------- |
| Connectedness     | **High**            | Low      | **High** |
| Completeness      | **High**            | Low      | Depends  |
| Simplicity        | Depends             | **High** | Low      |
| Real-time Ability | Limited             | **High** | **High** |

### How to combine Plain Rx and LQR

- Rx **before** LQR: clean/normalize sources (map/filter/debounce).
- LQR for correlation/state: joins, anti-joins, distinct, grouped aggregates with explicit retention.
- Rx **after** LQR: map/filter/share results to consumers or side-effects without redoing correlation.


### Example Use cases

- **Game programming:** If a player enters zone Z and triggers beacon B within 3s, spawn encounter X; otherwise mark the attempt stale. 
> LQR handles the keyed, time-bounded join and emits unmatched/expired events for debugging balance.
- **Realtime personalization/ads:** Show offer O to users who viewed product P and then searched for related term T within 10s; drop the impression if no add-to-cart happens within 30s.
> LQR keeps streams keyed by user/session, joins them in windows, and emits expirations for dropped/late flows.
- **Security/fraud:** Flag logins from device X if they are followed by a high-value transaction from a different IP within 15s; rate-limit per account across sliding 5-minute windows.
> LQR joins streams by account/device and provides grouped aggregates for rate controls.
- **IoT/telemetry:** Join telemetry from sensor D with its latest config/firmware event; if no telemetry arrives for 60s, emit a stale alert; group per site to cap concurrent stale devices.
> LQR bring Cross-stream correlation, staleness, and grouped caps.

---

## Documentation

- **User & API docs:** see [docs/](docs/README.md) (table of contents and links into conceptual guides, how‑tos, and references).
- **Development workflow:** see [docs/development.md](docs/development.md).

---


## Props & Credits

LQR builds directly on the work of others in the Lua ReactiveX ecosystem:

- [`christophstrasen/lua-reactivex`](https://github.com/christophstrasen/lua-reactivex) — forked from `4O4/lua-reactivex`, expected at `./reactivex` in this repo.
- [`bjornbytes/RxLua`](https://github.com/bjornbytes/RxLua) — the original Rx implementation

If you are new to ReactiveX in Lua, both repositories and especially [ReactiveX](https://reactivex.io/) are worth a look.

---

## AI Disclosure

Parts of this project’s code, tests and documentation were drafted or refined with the assistance of AI tools (including OpenAI’s ChatGPT).  
All code and text have been **reviewed and edited by a human** before inclusion.

No assets, proprietary content, or copyrighted material were conciously generated, reproduced, or distributed using AI tools.

---

## Disclaimer

LQR is provided entirely **AS‑IS** — still experimental and evolving.  
There are no guarantees, no stable releases, and not even a firm notion of versioning at this point.  
It may change tomorrow or be abandoned without notice.

By using or modifying this code, you accept that:

- You do so at your own risk.
- The authors take no responsibility for any harm, loss, or unintended side effects
- There is no warranty, express or implied
- Licensed under the MIT License (see the `LICENSE` file for details).
