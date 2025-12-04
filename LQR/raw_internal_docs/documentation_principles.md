# LQR Documentation Principles

This note captures the guiding principles for how we document LQR. It is intended for maintainers and contributors so that new docs and examples stay coherent as the project grows.

## 1. Goals and Audience

- **Primary audience:** non‑casual engineers who are comfortable with Lua and curious about or least vaguely familiar with ReactiveX or event‑driven systems.
- **Secondary audience:** advanced Project Zomboid / Starlit modders willing to invest in a more declarative, streaming‑style toolkit.
- **Goal:** make it possible to understand and use LQR without reading the entire codebase or every design log, by providing a layered, honest description of what the system does and does not do.

## 2. Layered Documentation Structure

We keep a clear separation between user‑facing docs and internal design notes:

- **Root `README.md`**
  - High‑level overview and value proposition.
  - Integrated Quickstart example that a new user can run in a few minutes.

- **`docs/` (user‑facing)**
  - Clean, curated material only.
  - Structure (target state, not all files exist yet):
    - `docs/concepts/` — core mental model (records, schemas, joins, windows, grouping, distinct).
    - `docs/guides/` — task‑oriented guides (joins, `where`, grouping, distinct, observability).
    - `docs/howto/` — short cookbook recipes.
    - `docs/integrations/` — integration guides (e.g., Starlit / Project Zomboid).
    - `docs/reference/` — stable API reference for `LQR.Query`, `LQR.Schema`, `JoinObservable`, `GroupByObservable`, helpers.

- **`LQR/raw_internal_docs/` (internal)**
  - Design briefs, logbook, refactor plans, and any “day X” experiment notes.
  - May be longer, more exploratory, or partially outdated; they are still valuable context for contributors.

When in doubt: if a document primarily exists to help end‑users build queries, it should live (or eventually move) under `docs/`. If it mostly records design trade‑offs or historical decisions, it belongs in `LQR/raw_internal_docs/`.

## 3. Content Principles

- **One new idea per page (as much as possible)**
  - Avoid mixing several new concepts (e.g., join windows, per‑key buffers, and distinct) in the same introductory page.
  - It is fine to link forward (“we’ll revisit this when we talk about `distinct`”) instead of explaining everything at once.

- **Sticky vocabulary**
  - Always use the project glossary terms:
    - `record` — single emission flowing through Rx graphs.
    - `schema` / `schema name` — logical label describing record type and how we address it in joins.
    - `JoinResult` — container emitted by joins, indexed by schema name.
    - `row` — schema‑aware view over a joined emission (`row.<schema>` tables used by `where`/grouping), built from a `JoinResult`.
    - `join window` — retention policy for join caches.
    - `group window` — retention policy for grouping windows.
    - `expired` stream — observability stream of removals from caches/windows, not “business results”.
    - `LQR` when using the library name professional, `LiQoR` when we want to be a bit cheeky
  - Do not invent ad‑hoc synonyms for these concepts inside docs.

- **SQL hooks, but honest streaming semantics**
  - It is fine to explain features in SQL terms (`FROM / JOIN / ON / WHERE / GROUP BY / HAVING`) and to show SQL⇄DSL mappings.
  - Always call out where streaming differs from classic SQL:
    - results are continuous streams, not static snapshots;
    - windows bound memory and correctness;
    - the same logical row may appear multiple times as events flow and expire.
    - teach or explore concept of "Not the entities are streamed but observations about them."

- **Examples over theory**
  - Prefer short, concrete examples over abstract descriptions.
  - Reuse a small set of domains across docs (see below) to keep cognitive load low.

- **Observability early**
  - Introduce `builder:expired()` and logging early in guides (including Quickstart), not as an afterthought.
  - Make it clear that expired streams are for understanding retention behavior, not “failed business events”.

## 4. Example Domains

To keep readers oriented, we reuse a small set of example domains throughout the docs:

- **Customers / orders / refunds**
  - Good for straightforward SQL‑style joins and simple financial aggregates.

- **Animals (lions / gazelles)**
  - Useful for grouping and HAVING examples (“herds per location”, “only emit once at least N have gathered”).

- **Zombies / squares / rooms (Project Zomboid)**
  - For integration guides and game‑specific how‑tos (e.g., “zombies per room in the last 10 seconds”).

When adding new examples, prefer to map them back to one of these domains unless there is a very strong reason to introduce a new one.

## 5. Style & Tone

- **Direct and precise**
  - Write for engineers; avoid marketing language.
  - Prefer short, declarative sentences and concrete claims.

- **Explain trade‑offs explicitly**
  - Call out non‑deterministic emission ordering and why we accept it (throughput/latency).
  - Explain memory vs correctness trade‑offs for join windows, group windows, and per‑key buffers.
  - Clarify how `distinct` behaves (first‑seen wins until it expires; duplicates surface on `expired()`).

- **Minimal, focused diagrams**
  - Where helpful, include simple diagrams (textual or eventual images) to show timelines, windows, and cache behavior.
  - Diagrams should explain exactly one concept; avoid “kitchen sink” visuals.

## 6. Keeping Docs Aligned with Code

- Update or at least sanity‑check the relevant docs whenever:
  - the public `LQR.Query` or `LQR.Schema` surface changes;
  - join/window/grouping semantics change;
  - we add/remove major operators (`distinct`, viz hooks, etc.).
- When behavior changes in a non‑obvious way, prefer:
  - a short note in `project_logbook.md` (what changed and why); and
  - an update to any affected user‑facing guide under `docs/`.

## 7. “Good Citizen” Checklist for New Docs

Before merging a new or heavily edited document, check:

- Does it fit into the structure in §2 (overview, concept, guide, how‑to, reference, or internal)?
- Does it reuse the glossary terms from `context.md` and §3?
- Does it introduce at most one major new concept at a time?
- Does it show at least one concrete example or scenario?
- If it describes behavior that differs from SQL or from “typical Rx”, does it say so explicitly?
- If it is largely historical or exploratory, does it live under `LQR/raw_internal_docs/`?

Following these principles should make LiQoR approachable for new users while still reflecting the full complexity of streaming joins and grouped analytics on top of ReactiveX.
