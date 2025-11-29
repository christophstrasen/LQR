# LQR Documentation

This folder is the entry point for LQR’s user‑facing documentation. It is meant to stay concise and structured, while deeper design notes and historical documents live under `LQR/raw_internal_docs/`.

At the moment, the main places to explore are:

- **Overview & Quickstart**
  - `README.md` in the repository root — high‑level description of LQR and a minimal join example.

- **Concepts (streaming joins & grouping)**
  - `docs/concepts/records_and_schemas.md` — user‑facing introduction to records, schemas, `RxMeta`, `JoinResult`, and the row view used by `where` and grouping.
  - `docs/concepts/joins_and_windows.md` — how streaming joins work in LQR, join types, join windows (count/time), per‑key buffers, and the `expired()` side channel.
  - `docs/concepts/where_and_row_view.md` — row‑level filtering with `where`, how the row view looks, and how to write predicates that behave well for inner and outer joins.
  - `docs/concepts/grouping_and_having.md` — how to express streaming `GROUP BY` / `HAVING` with `groupBy` / `groupByEnrich`, group windows, and group‑level predicates.

- **Guides**
  - `docs/guides/building_a_join_query.md` — end‑to‑end example: define schema‑tagged sources, join them by key with a window, filter with `where`, and subscribe to both joined rows and `expired()`.
  - `LQR/raw_internal_docs/explainer.md` — how LQR thinks about records, schemas, join windows, expirations, and visualization.
  - `LQR/raw_internal_docs/data_structures.md` — precise shapes for inputs, join outputs, and grouped views.

- **High‑level query API drafts**
  - `LQR/raw_internal_docs/high_level_api.md` — intended fluent surface (`Query.from`, joins, `on`, `joinWindow`, selection).
  - `LQR/raw_internal_docs/where_clause_briefing.md` — `WHERE`‑style filtering over joined rows.
  - `LQR/raw_internal_docs/group_by_briefing.md` — `GROUP BY` / `HAVING` semantics and aggregate/enriched views.

- **Low‑level internals**
  - `LQR/raw_internal_docs/low_level_api.md` — `JoinObservable.createJoinObservable` and retention/expiration mechanics.
  - `LQR/raw_internal_docs/project_logbook.md` — day‑by‑day evolution of the join, grouping, distinct, and viz layers.
  - `LQR/raw_internal_docs/per_key_buffer_refactor.md` — design notes for per‑key buffers and overwrite expirations.
  - `LQR/raw_internal_docs/logging.md` — logging conventions and log‑level helpers.

As the API stabilizes, new, cleaned‑up guides and references will be added under `docs/` itself (e.g., `docs/concepts/`, `docs/guides/`, `docs/reference/`) and this README will be updated into a full table of contents.
