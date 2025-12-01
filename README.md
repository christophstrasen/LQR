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

It is designed for in‑process, single‑threaded environments like Lua game runtimes, but is usable in any Lua 5.1 host that can run lua‑reactivex.

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

-- 2) Build a streaming left join: customers ⟕ orders ON id = customerId.
local query =
  Query.from(customers, "customers")
    :leftJoin(orders, "orders")
    :on({ customers = "id", orders = "customerId" })
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

See the `examples.lua` file and the tests under `tests/unit` for more complete scenarios.

---

## Documentation

- **Overview & Quickstart:** this `README.md`.
- **User & API docs:** see `docs/` (table of contents and links into conceptual guides, how‑tos, and references).

--- 
## Development Workflow for work LQR

This section concerns the development of LQR itself.

### Hooks

This project uses [pre-commit](https://pre-commit.com/) to ensure fast feedback before code is committed.

### Prerequisites

- Install pre-commit (via `pip install pre-commit` or your package manager).
- Ensure `busted` is installed and available on your PATH.

### Setup

Run this once after cloning:

```bash
pre-commit install
```

This installs the Git hook that automatically runs `busted tests/unit` before each commit.

### Manual Run

You can run the hook manually against all files:

```bash
pre-commit run --all-files
```

---

## JoinObservable defaults

- Joins support count-, interval/time-, and predicate-based expiration join windows.
- By default, unmatched rows are flushed on completion with `reason="completed"`. Set `flushOnComplete=false` when creating a join to suppress the final flush if you need legacy behavior.
- Optional GC helpers:
  - `gcIntervalSeconds` will run a periodic expiration sweep if a scheduler is available (either provide `gcScheduleFn(delaySeconds, fn)` or run under a TimeoutScheduler/luvit timers).
  - `gcScheduleFn` lets hosts plug in their timer API; otherwise the join falls back to opportunistic GC when new records arrive. The scheduler can return either an object with `unsubscribe`/`dispose` or a plain cancel function; it will be invoked when the join is disposed.

---

## Props & Credits

LQR builds directly on the work of others in the Lua ReactiveX ecosystem:

- [`4O4/lua-reactivex`](https://github.com/4O4/lua-reactivex) — the concrete ReactiveX implementation this project vendors and extends.
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
