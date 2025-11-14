# AI Context — Lua-ReactiveX-exploration

> Single source of truth for how ChatGPT should think and work in this repo.

## 1) Interaction Rules (How to Work With Me)
- **Assume** this `context.md` is attached for every task and make sure you load it.
- **Cut flattery** like "This is a good question" etc.
- **Hold before coding** Do not present code for simple and clear questions. If you think you can illustrate it with code best, use small snippets and ask first.
- If you must choose between guessing and asking: **always ask**, calling out uncertainties.
- When refactoring: preserve behavior; list any intentional changes.
- **Warn** when context may be missing
- **Keep doc tags** when presenting new versions of functions, including above the function header
- **Stay consistent** with the guidance in the `context.md` flag existing inconsistencies in the codebase as a "boy scout principle"
- **Bias for simplicity** Keep functions short and readable. Do not add unasked features or future-proofing unless it has a very clear benefit
- **Refer to source** Load and use the sources listed in the `context.md`. If you have conflicing information, the listed sources are considered to be always right.
- **offer guidance** When prompted, occasionally refer to comparable problems or requirements in the context of Project Zomboid, Modding or software-development in general.
- **stay light-hearted** When making suggestions or placing comments, it is ok to be cheeky or have a Zomboid-Humor but only as long as it doesn't hurt readability and understanding.
- **Ignore Multiplayer/Singleplayer** and do not give advice or flag issues on that topic.
* **Start high level and simpel** when asked for advice or a question on a new topic, do not go into nitty gritty details until I tell you. Rather ask if you are unsure how detailed I wish to discuss. You may suggest but unless asked to, do not give implementation or migration plan or details.
* **prefer the zomboid way of coding** e.g. do not provide custom helpers to check for types when native typechecking can work perfectly well.
* **Classify your code comments** Into different categories. I see at least these two frequent categoroes "Explainers" that describe the implemented concepts, logic or intent and "Implementation Status" That highlights how complete something is, if we look at a stub, what should happen next etc.
* **Code comments explain intent** When you leave comments, don't just describe what happens, but _why_ it happens and how it ties in with other systems. Briefly.
* **Write tests and use them** when we refactor, change or expand our module work (not necessary when we just run experiments).
* **prefer minimal-first solutions** When designing system extensions, do not put in optional and nice-to-have fluff.
* **No legacy** do not build shims, wrappers or aliases when we can instead change the callsites directly.

## 2) Output Requirements
- **never use diff output** But only copy-paste ready code and instructions
- **Be clear** about files and code locations
- **Use EmmyLua doctags** Add them and keep them compatible with existing ones.
- **Respect the Coding Style & Conventions** in `context.md`

## 3) Project Summary
- Implement a query and join system that works on Lua-ReactiveX observables and allows for an sql-like building and running of queries over multiple observables and sources with a fluent, user-friendly API and handling. In a nutshell "Single thread, non-blocking stream processing in lua with a ReactiveX backbone and an SQL-Like interface"

## 4) Tech Stack & Environment
- **Language(s):** Lua 5.1. Later: Zomboid (Build 42) runtime on kahlua vm.
- **Testing** we use `busted` for test
- **CI** we use github actions and pre-commit
- **Editor/OS:** VS Code with VIM support on NixOS.
- **Authoritative Repo Layout**
```
tbd
```


## 5) External Sources of Truth (in order)

- **ReactiveX main website** 
  https://reactivex.io/documentation

- **Lua-ReactiveX github**
  https://github.com/4O4/lua-reactivex

- **Lua-ReactiveX luarocks module**
  https://luarocks.org/modules/4o4/reactivex

- **Starlot LuaEvent** 
  https://github.com/demiurgeQuantified/StarlitLibrary/blob/main/Contents/mods/StarlitLibrary/42/media/lua/shared/Starlit/LuaEvent.lua

  ### Sourcing Policy
1. reactivex.io describes principles and "ideal API" but implementations may differ
2. lua-reactivex is the authorative implementation we can use

## 6) Internal Sources and references

- **This projects github**
  https://github.com/christophstrasen/Lua-ReactiveX-exploration

## 7) Coding Style & Conventions
- **Lua:** EmmyLua on all public functions; keep lines ≤ 100 chars. Scene prefabs are exempt from strict style enforcement. 
- **Globals:** If possible, avoid new globals. If needed, use **Capitalized** form (e.g., `SomeTerm`) 
- **use ReactiveX base** like `rx.Observable.` in order to typehint to EmmyLua correctly
- **Record as atomic unit** Our canonical name for each "emmission, element, value, packet" that goes through the ReactiveX system, through our streams and event system is called "record".
- **Naming:** `camelCase` for fields, options, and functions (to match PZ API)  `snake_case` for file-names.
- **Backwards-compatibility** Hard refactors are allowed during early development. Compatibility shims or aliases are added only for public API calls — and only once the mod has active external users.
- **Avoid:** `setmetatable` unless explicitly requested.
- **Graceful Degradation:** Prefer tolerant behavior for untestable or world-variance cases. Try to fall back and emit a single debug log, and proceed. .
- **Schema metadata is mandatory:** Any record entering `JoinObservable.createJoinObservable` must already carry `record.RxMeta.schema` and a stable `record.RxMeta.id` (use `Schema.wrap` with `idField`/`idSelector`). Minimal fields: `schema` (string), `id` (any), optional `schemaVersion` (positive int), optional `sourceTime` (number). The join stamps `RxMeta.joinKey` itself.
- **Chaining joins:** Prefer `JoinObservable.chain` + `JoinResult.selectSchemas` over manual subjects when forwarding schema names to downstream joins. Treat intermediate payloads as immutable unless you intentionally mutate them right before emitting.
- **Join outputs are schema-indexed:** Subscribers receive `JoinResult` objects—call `result:get("schemaName")` instead of relying on `pair.left/right`. Expiration packets expose `packet.schema` and `packet.result`.

## 8) Design Principles
- Favor throughput/low latency over strict determinism: the low-level join does not guarantee globally stable emission ordering. If a flow needs determinism, use custom merge/order operators on the way in instead of burdening the core path.

## 9) Security & Safety
- No secrets in repo; assume public visibility.
- Respect third-party licenses when borrowing examples.

## 10) Agent Mode
- Assume NixOS Linux with `zsh` as the available shell; do not re-verify shell/OS each task.
- Local Lua runtime 5.1 ist installed and exists
- Treat the workspace as sandboxed; only the repository under `~/projects/Lua-ReactiveX-exploration` is writable unless instructed otherwise.
- Shell startup emits benign `gpg-agent` warnings; ignore them unless the user flags an issue.
- do NOT run love/löve/love2d yourself
- do NOT any modifying git commands unless instructed or before asking permission from me.
- After every code-change, run `busted tests/unit` and check the result

## 11) Project Glossary
- **record**: Single emission flowing through Rx graphs. Always a Lua table carrying payload fields plus `record.RxMeta` metadata (`schema`, optional `schemaVersion`/`sourceTime`, mandatory `id/idField`, and the join’s `joinKey` once computed).
- **schema**: Logical contract describing the shape and intent of a record type (e.g., “orders”, “payments”). We enforce schema tagging by wrapping sources with `Schema.wrap`, which also validates metadata.
- **schema name**: Human-readable label assigned via `Schema.wrap("name", observable)` or renamed later via `JoinResult.selectSchemas` / `JoinObservable.chain`. Joins and downstream consumers address records by this label (e.g., `result:get("customers")`).
- **JoinResult**: Container emitted by `JoinObservable.createJoinObservable`. Behaves like a table keyed by schema name and exposes helpers such as `get`, `schemaNames`, `clone`, `selectSchemas`, and `attachFrom`.
- **expired record**: Object emitted by the secondary observable returned from `createJoinObservable`. Shape: `{ schema, key, reason, result }`, where `result` is a `JoinResult` containing only the expired record.
- **join window / retention policy**: Configuration that decides how long cached records stick around (`count`, `interval`, `time`, or `predicate` modes). Once a record ages out we emit the expirated record and optionally an unmatched result.
- **chain**: Helper (`JoinObservable.chain`) that forwards one or more schema names from an upstream `JoinResult` stream into fresh schema-tagged observables so downstream joins can subscribe without manual Subjects.
- **mergeSources**: Optional function in join options that replaces the default `left:merge(right)` behavior. Used for custom ordering/buffering before records hit the caches.
