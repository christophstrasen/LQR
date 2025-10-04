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

## 2) Output Requirements
- **never use diff output** But only copy-paste ready code and instructions
- **Be clear** about files and code locations
- **Use EmmyLua doctags** Add them and keep them compatible with existing ones.
- **Respect the Coding Style & Conventions** in `context.md`

## 3) Project Summary
- experimenting with the possibilities, principles etc. of Lua-ReactiveX

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
- **Schema metadata is mandatory:** Any record entering `JoinObservable.createJoinObservable` must already carry `record.RxMeta.schema` (via `Schema.wrap`). Minimal fields: `schema` (string), optional `schemaVersion` (positive int), optional `sourceTime` (number). The join stamps `RxMeta.joinKey` itself.
- **Chaining joins:** Prefer `JoinObservable.chain` + `JoinResult.selectAliases` over manual subjects when forwarding aliases to downstream joins. Treat intermediate payloads as immutable unless you intentionally mutate them right before emitting.
- **Join outputs are schema-indexed:** Subscribers receive `JoinResult` objects—call `result:get("schemaName")` instead of relying on `pair.left/right`. Expiration packets expose `packet.alias` and `packet.result`.

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
