# Distinct and deduplication

Streams often contain **many observations about the same entity**:

- sensors that send the same reading more than once;
- game events that repeat a state change (`door=open` 10 times);
- joins that produce several rows for the same schema key in a short time.

Sometimes you want to treat “first seen for this key in this window” as special and
ignore the rest. That is what LQR’s **`distinct`** operator is for.

---

## Why `distinct` exists

Join and group windows answer:

- “for how long can this **record** stay relevant for joins or aggregates?”

`distinct` answers a different question:

- “for how long do we remember that we have already seen an **entity key**?”

In other words:

- if a key is **still remembered** by `distinct`, new events with the same key are treated as *duplicates* and suppressed on the main stream;
- once a key **falls out** of the distinct window, the next event with that key is treated as *new* again.

This lets you:

- avoid doing expensive work (joins, grouping, I/O) for repeated observations;
- keep your downstream metrics closer to “distinct entities” instead of “all noisy events”.

---

## Where `distinct` fits in the pipeline

At the high level you use:

```lua
Query.from(lions, "lions")
  :distinct("lions", { by = "name" })
  -- further joins / where / grouping…
```

`QueryBuilder:distinct(schemaName, opts)` is a **builder‑level** operator. It can be placed:

- **before joins** – dedupe a source schema before it ever reaches joins or grouping;
- **after a join** – dedupe based on one schema inside a `JoinResult` (e.g. “only the first joined row per lion id”);
- **before grouping** – reduce noise so group windows count “unique entities” instead of all repeats, making sums and averages more meaningful and not skewed by repeat observations.

---

## Basic usage

The minimal configuration is:

```lua
Query.from(lions, "lions")
  :distinct("lions", {
    by = "name",   -- field (dot path) or function
  })
```

Behavior:

- for each **key** produced by `by`, the **first** record that arrives in the distinct window is emitted;
- later records with the same key are **suppressed** on the main stream while the key is remembered;
- suppressed duplicates are still visible on `query:expired()` with `origin = "distinct"` and `reason = "distinct_schema"`.

You can also pass a function as `by`:

```lua
:distinct("lions", {
  by = function(entry)
    -- anything that identifies “the same lion” for your case
    return entry.name
  end,
})
```

If the key function errors or returns `nil`, that record is dropped from `distinct` (with a warning) and simply does not participate in deduplication.

---

## Choosing a dedup key

The `by` option decides which events should be considered “the same” for deduplication. Some guidelines:

- **Think in entities, not events.**  
  Use a stable identifier for the thing you care about (customer id, lion id, room id, …), not a transient field like “HP” or “distance”.

- **Use a field path when possible.**  
  `by = "id"` or `by = "customers.id"` is cheap and easy to read.

- **Use a function for composite keys.**  
  For example:

  ```lua
  by = function(entry)
    return entry.roomId .. ":" .. entry.zone
  end
  ```

- **Keep it cheap and deterministic.**  
  No I/O, no randomness; same input record → same key.

For joined streams, `by` sees the **schema record** (`result:get(schemaName)`), not the full row view: use field paths or functions that make sense on that record.

---

## Distinct windows (how long keys are remembered)

Internally, `distinct` maintains a small cache with **at most one entry per key**. The **window** controls:

- how many different keys we remember at once (count window); or
- for how long each key stays remembered (time window).

You configure this via `opts.window`:

```lua
-- Count-based: remember up to 1 000 keys
:distinct("lions", {
  by = "id",
  window = { count = 1000 },
})

-- Time-based: remember keys for 5 seconds of event time
:distinct("lions", {
  by = "id",
  window = {
    time = 5,             -- seconds
    field = "sourceTime", -- optional; defaults to "sourceTime"
    currentFn = os.time,  -- optional; defaults to os.time
  },
})
```

Semantics:

- **Count window**  
  - we remember at most `count` different keys at a time;  
  - when a new key would exceed that, the **oldest** remembered key is evicted; after eviction, the next event for that key is treated as new.
  - **Caution:** if the total number of distinct keys never reaches `count`, those keys are effectively remembered for the whole runtime of the query (duplicates will always be suppressed unless you change the key).

- **Time window**  
  - we remember a key while `currentFn() - entry[field] <= time`;  
  - once that condition fails, the key is evicted; a later event with the same key is treated as new again.

In both cases:

- duplicates that arrive **while a key is remembered** are suppressed and surfaced on `expired()` with `origin = "distinct"`;
- when the window drops a remembered key, you see additional expirations for the surviving entry (same infrastructure and reasons as join/group windows, e.g. `evicted` or `expired_interval`).

If you omit `window`, `distinct` uses a count‑based window with a reasonable default size to avoid unbounded memory.

> **Recommendation**  
> In most cases a **time‑based** distinct window is the safer default: it guarantees that keys are forgotten after some duration, even when the total number of keys is small.  
> If you do need expiration‑like behavior with a pure count window (for example, “distinct per entity per coarse time bucket”), you might want to implement your own "cache busting", e.g. by encoding time into the key yourself: `by = function(entry) return entry.name .. ":" .. hour(entry.sourceTime) end`.

---

## How `distinct` interacts with other windows

If you have read [joins_and_windows](joins_and_windows.md), you have already seen join windows. It helps to separate the roles of the different windows:

- **Join window** (`joinWindow`)  
  Controls how long individual **records** stay eligible to participate in joins.

- **Group window** (`groupWindow`)  
  Controls over which slice of time/rows you compute **aggregates per key**.

- **Distinct window** (`window` on `distinct`)  
  Controls for how long you remember **which keys you have already seen** so duplicates can be suppressed.

You can freely combine them. For example:

- dedupe noisy sensor updates per entity with `distinct` over a 5‑second time window;
- then join the deduped stream with something else using a join window tuned for matching latency;
- then group and aggregate over a longer group window for metrics.

The windows are independent knobs; they all bound memory, but at different layers of the pipeline.

---

## `distinct` vs. join `oneShot`

There are two places where you can influence “how often” a record participates in results:

- **Schema‑level `distinct`** — a standalone operator in the builder chain that keeps at most one entry per key in its own cache and suppresses later events with the same key while that key is remembered.
- **Join‑side `oneShot`** — an option on a specific join side (via `on{ ..., oneShot = true }`) that consumes a cached record on that side after its first match on that join step, so that particular cached entry is used at most once.

As a rule of thumb:

- use **`distinct`** when you want to say “treat repeated observations of this entity as duplicates for a while” at the schema level;  
- use **`oneShot`** when you specifically want join caches to behave in a consume‑on‑match way for a given side.

For more detail on join‑side options, see the “joins and windows” concept doc.

---

## Observing duplicates via `expired()`

`distinct` participates in the same `expired()` pipeline as joins and grouping. For a query with a distinct stage:

```lua
local query =
  Query.from(lions, "lions")
    :distinct("lions", { by = "id" })

query:expired():subscribe(function(packet)
  print(("[expired] origin=%s schema=%s key=%s reason=%s"):format(
    tostring(packet.origin),
    tostring(packet.schema),
    tostring(packet.key),
    tostring(packet.reason)
  ))
end)
```

You can expect:

- `origin = "distinct"` for all expirations coming from the distinct cache;
- `reason = "distinct_schema"` for suppressed duplicates (one packet per dropped duplicate);
- additional reasons such as `evicted` / `expired_interval` / `completed` when the distinct window itself forgets keys.

Treat this as **observability**, not business logic: it is a good way to answer questions like:

- “how often do duplicates occur per key?”  
- “how aggressively does my distinct window evict remembered keys?”

without changing your main query behavior.
