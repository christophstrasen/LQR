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
