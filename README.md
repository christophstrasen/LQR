# Lua ReactiveX Exploration

[![CI](https://github.com/christophstrasen/Lua-ReactiveX-exploration/actions/workflows/ci.yml/badge.svg)](https://github.com/christophstrasen/Lua-ReactiveX-exploration/actions/workflows/ci.yml)

## Development Workflow

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

## Continuous Integration

GitHub Actions runs `busted tests/unit` on pushes and pull requests targeting `main` (see `.github/workflows/ci.yml`).

## JoinObservable defaults

- Joins support count-, interval/time-, and predicate-based expiration join windows.
- By default, unmatched rows are flushed on completion with `reason="completed"`. Set `flushOnComplete=false` when creating a join to suppress the final flush if you need legacy behavior.
- Optional GC helpers:
  - `gcIntervalSeconds` will run a periodic expiration sweep if a scheduler is available (either provide `gcScheduleFn(delaySeconds, fn)` or run under a TimeoutScheduler/luvit timers).
  - `gcScheduleFn` lets hosts plug in their timer API; otherwise the join falls back to opportunistic GC when new records arrive. The scheduler can return either an object with `unsubscribe`/`dispose` or a plain cancel function; it will be invoked when the join is disposed.
