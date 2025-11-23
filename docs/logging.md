# Logging guide

- The shared logger lives in `util/log.lua`. Levels: `fatal`, `error`, `warn`, `info`, `debug`, `trace`. Default is `warn`, unless `LOG_LEVEL` is set or `DEBUG=1` (implies `debug`).
- Tagging: `local Log = require("util.log").withTag("join")` then `Log.warn("...")`/`Log.debug("...")`. Use tags per subsystem (e.g., `join`, `viz-hi`, `viz-lo`, `demo`).
- Costly logs: wrap in `if Log.isEnabled("debug") then ... end` to avoid expensive formatting.
- Scoped suppression: `Log.supressBelow("error", function() ... end)` temporarily mutes logs below `error` while running the function (restores the previous level afterwards). Tests can use this to silence chatty warnings.
- Keep user-facing prints in examples only; production modules should go through the logger so env-level control works.***
