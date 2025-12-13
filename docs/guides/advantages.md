# Advantages of LQR

This guide explains why a streaming query system like LQR is useful when you mostly know:

- imperative Lua (loops and tables);
- event‑driven code (callbacks and handlers); and
- relational SQL (`SELECT`, `JOIN`, `GROUP BY`).

---

## Queries that stay mounted and update incrementally

In SQL you usually “run a query”, get a result, and stop.
In LQR you “mount a query” and keep it running.

- You define a query once and subscribe to it.
- As new events arrive, the query emits new results.
- You do not need to write a loop that polls or re‑runs the query.

This has a big effect on how you think:

- You stop asking “when do I re‑compute this?”.
- You start asking “how should changes flow through this pipeline?”.

Aggregates are incremental, not batch‑based:

- Counts, sums, and “current state” update as each event arrives.
- You do not re‑scan a whole table on a timer.
- There is less work and less latency than a periodic batch job.

This is helpful for:

- dashboards that must stay live without reloads;
- alerts that should fire as soon as a pattern appears; and
- game or app logic that should react to events, not to cron jobs.

---

## Per‑key state that manages itself

Many problems are per <entity>, e.g. “per device”, or “per customer”.  
In LQR each key can behave like its own little state machine.

In the example of a scoreboard for a sports match:

- You have one stream of player events with `matchId`, `playerId`, and `eventType`.
- You define a query that groups by `matchId` and counts goals per player.
- When a new `matchId` appears, LQR creates state for that match and starts tracking its players.
- While the match runs, events for that `matchId` update only that match’s scoreboard.
- When the match ends (for example, after a time window), the group for that `matchId` can expire and free its state.

The query describes what should happen per match.
The runtime applies that logic to all matches at once.

Compared to imperative code:

- instead of a giant loop with `stateByMatchId[matchId]` and many `if`s;
- or many different event handlers that all poke into shared match tables;
- you describe the per‑match flow in one place;
- and LQR keeps separate state per match for you.

This keeps code smaller and easier to reason about, even when:

- there are many keys;
- keys are very short‑lived (like matches or sessions); or
- you do not know the key set in advance.

---

## Many views over the same events

Staying with the sports match example, from the same event streams you might want:

- per‑match scoreboards (like above);
- per‑player stats across many matches; and
- per‑country or per‑region summaries.

In table‑based code you either:

- loop many times over the same events; or
- keep several accumulator tables inside one complex loop; or
- wire several event handlers that each update their own accumulators.

With LQR you can:

- have one query that keeps a per‑match scoreboard;
- another query that groups by `playerId` and tracks long‑term stats; and
- a third query that groups by `mapId` and tracks map balance.

All three consume the same underlying event streams.
Each grouping has its own state, windows, and lifecycles.

Adding one more view later (for example, per team) usually just means adding another query that reuses the same base event stream and query, without refactoring existing loops or shared state.

---

## Time is a first class concept

In SQL you usually join tables that feel “timeless”:  
rows are either there or not, and the join doesn't need to care when they were created.

In event streams the **when** is often the main question:

- “did a purchase happen shortly after a login?”;
- “did a player ready up within 30 seconds of a match invite?”; or
- “did a confirmation event arrive in time for a request?”.

LQR joins work over a window of time or count:

- matching events must share a key **and** be close enough in time (or position) to count as a pair;
- you decide how long they are allowed to wait for each other.

This gives a few concrete advantages:

- you describe “match within N seconds” directly in the query instead of hand‑rolling timers;
- you do not have to invent your own rules for “how long do we wait?” in many different places; and
- you can make “too late” or “never happened” a visible outcome instead of a silent failure.

This matters most in flows where:

- players, users, or systems are supposed to react quickly (invites, ready checks, prompts);
- money or items move between parties (purchases, trades, rewards); or
- you care about promises and timeouts (requests that must be confirmed, tasks that must complete).

In those situations a time‑aware join gives you both:

- the happy‑path pairs that matched in time; and
- a clean way to see and act on everything that did not.

---

## One place for cross‑stream domain logic

Manually combining event- and streaming logic together with static state and polling can easily result in scattered logic that can be difficult to reason about:

- some lives in database queries;
- some in Lua loops that stitch tables together; and
- some in callbacks or handlers across modules.

With LQR you can put related logic into one query pipeline:

- describe which sources feed in;
- describe how they join, filter, and group; and
- subscribe to the result and to expiration signals.

This has a few concrete benefits:

- easier review: “how do these streams interact?” has one answer;
- easier testing: you can drive the query with sample events; and
- easier change: adding a new condition or join is a local change.

For game or app code this often means:

- less shared mutable state in global tables;
- fewer subtle order‑of‑handler bugs; and
- clearer separation of “what should happen” from “how we store" and "how we pipe it”.

If your code base is full of “when event X fires, update table Y” handlers, particular some who manage their own state, then moving cross‑stream rules into a query can make the overall logic easier to follow.

Additionally, because LQR is built on lua‑reactivex, that query is just another stream: you can use the same simple operators to pre‑process source streams before they enter the query and to post‑process the joined result afterwards.

---

## Helps avoid overload and spikes

Imperative code often has loops like “while true: read input and process”.
If that loop reads faster than the rest of the system can handle, you get:

- unbounded queues;
- rising memory; and
- unpredictable latency spikes.

LQR sits on top of a push‑based streaming model:

- data is pushed to subscribers instead of pulled by tight loops;
- you can configure buffering, dropping, or throttling; and
- you can tune internal windows and buffers so LQR keeps only as much data in memory as you are comfortable with.

In practice this means you can:

- protect slow consumers from fast producers by trimming or smoothing spikes; and
- reason about load in the same place you describe the query.

Disclaimer: While, in principle, downstream speed can help limit upstream work when sources are written to respect that, today lua‑reactivex and LQR do not have a full “backpressure protocol” where consumers explicitly signal demand.  
You still have to design the boundaries of your system (network input, game loop, disk readers) so they respect whatever buffering or throttling strategy you choose. Furthermore it may be smart to use regular lua‑reactivex operators (for example, buffering or sampling) to reduce or reshape traffic before it hits more expensive query stages. Future versions of LQR and lua-reactivex might allow some of these limits to be adjusted dynamically at runtime.

If you are in a tick-driven host (games/sims/UI loops) and you can’t afford to process bursts inside event handlers, use `LQR/ingest` at the source boundary:

- `buffer:ingest(...)` in the event handler (cheap)
- `buffer:drain({ maxItems = N, ... })` on your tick (budgeted)

See `docs/concepts/ingest_buffering.md` for details and examples.

---

## Handles late, missing, and out‑of‑order events

As in many systems time is an afterthought, we often find code that code quietly assume events:

- arrive quickly;
- arrive once; and
- arrive in order.

Real systems break those assumptions:

- network jitter reorders events;
- retries cause duplicates; and
- spikes cause delays.

LQR makes time and order explicit:

- you can choose which field carries event time;
- you can define windows in seconds or counts; and
- you can decide what “too late” means for a use case.

Because these choices are part of the query:

- you can review them like any other logic;
- you can test “late event” scenarios in a controlled way; and
- you are less likely to rely on hidden timing assumptions.

On top of that, window sizes, per‑key buffers, `distinct`, and `oneShot` give you simple ways to keep noisy, duplicated, or overly chatty streams under control.

This makes the system more predictable when reality gets messy.
