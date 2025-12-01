# LQR Documentation

This folder is the entry point for LQR’s user‑facing documentation.

What follows is a “guide of guides”: where to start and how to deepen your understanding.

---

## Start here

- **Root README**  
  [README.md](../README.md) — high‑level overview of LQR and a runnable Quickstart example, plus `expired()` explained early.

- **Records & schemas**  
  [records_and_schemas](concepts/records_and_schemas.md) — what a **record** is (event with `RxMeta`), what **schemas** are, how `JoinResult` and the **row view** are shaped, and why “observations, not entities” is the core mental model.

Once these two make sense, you have the vocabulary needed for all other docs.

---

## Core concepts

These pages explain the main concepts you will use in most queries:

- [joins_and_windows](concepts/joins_and_windows.md)  
  How streaming joins work in LQR, join types, when results appear (matched vs unmatched), join windows (count/time), per‑key buffers, and the `expired()` side channel. Also covers the important concept of join multiplicity and how `oneShot` "match-tickets".

- [where_and_row_view](concepts/where_and_row_view.md)  
  Row‑level filtering with `where`, using the row view (`row.<schema>` tables) for inner and outer joins, and how `where` relates to join windows and `expired()`.

- [grouping_and_having](concepts/grouping_and_having.md)  
  Streaming `GROUP BY` / `HAVING` with `groupBy` / `groupByEnrich`, group windows, aggregates, and `having`. Explains enriched vs aggregate views, how to access counts/sums/averages, and when to use `where` vs `having`.

- [distinct_and_dedup](concepts/distinct_and_dedup.md)  
  Schema‑aware deduplication with `distinct(schema, opts)`, how distinct windows remember keys (count/time), how duplicates surface on `expired()`, and how `distinct` composes with join/group windows and `oneShot`.

Suggested reading order:

1. [records_and_schemas](concepts/records_and_schemas.md)
2. [joins_and_windows](concepts/joins_and_windows.md)
3. [where_and_row_view](concepts/where_and_row_view.md)
4. [grouping_and_having](concepts/grouping_and_having.md)
5. [distinct_and_dedup](concepts/distinct_and_dedup.md)

---

## Guides (step‑by‑step)

Task‑oriented guides that walk through common scenarios:

- [building_a_join_query](guides/building_a_join_query.md)  
  End‑to‑end example: define schema‑tagged sources, join them by key with a window, filter with `where`, subscribe to both joined rows and `expired()`, and see how to combine LQR with standard lua‑reactivex operators (with links to ReactivX docs).

More guides (grouped queries, integration how‑tos, recipes) will live under `docs/guides/` as they are written.

---

## Internal design notes (optional)

These documents are **not** required to use LQR, but are useful if you want to understand internal mechanics or contribute to the library.

- [explainer.md](../LQR/raw_internal_docs/explainer.md)  
  How LQR thinks about records, schemas, join windows, expirations, and visualization; good for a deep conceptual dive.

- [data_structures.md](../LQR/raw_internal_docs/data_structures.md)  
  Precise shapes for inputs, join outputs, grouped views, and internal metadata.

- [high_level_api.md](../LQR/raw_internal_docs/high_level_api.md)  
  Intended fluent surface (`Query.from`, joins, `on`, `joinWindow`, selection) and notes on API evolution.

- [where_clause_briefing.md](../LQR/raw_internal_docs/where_clause_briefing.md)  
  Design notes behind the `where` operator and row‑view predicates.

- [group_by_briefing.md](../LQR/raw_internal_docs/group_by_briefing.md)  
  Internal explanation of `GROUP BY` / `HAVING`, aggregate vs enriched views, and grouping windows.

- [low_level_api.md](../LQR/raw_internal_docs/low_level_api.md)  
  `JoinObservable.createJoinObservable`, retention/expiration mechanics, and how join windows and per‑key buffers are implemented.

- [project_logbook.md](../LQR/raw_internal_docs/project_logbook.md)  
  Day‑by‑day evolution of joins, grouping, distinct, and visualization layers.

- [per_key_buffer_refactor.md](../LQR/raw_internal_docs/per_key_buffer_refactor.md)  
  Design notes for per‑key buffers and overwrite expirations.

- [logging.md](../LQR/raw_internal_docs/logging.md)  
  Logging conventions and log‑level helpers.

---

As the API stabilizes, more guides and a concise reference section will be added under `docs/`. This README should remain the main table of contents and navigation aid for the documentation set.
