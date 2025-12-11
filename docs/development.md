# Development workflow

This page covers working on LQR itself (not consuming it as a library).

## Hooks

We use [pre-commit](https://pre-commit.com/) for fast feedback before commits.

## Prerequisites

- Install pre-commit (via `pip install pre-commit` or your package manager).
- Ensure `busted` is installed and on your PATH.

## Setup

Run this once after cloning:

```bash
pre-commit install
```

This installs the Git hook that automatically runs `busted tests/unit` before each commit.

## Dependencies

LQR expects lua-reactivex to be available at the repo root in `./reactivex` (our fork at https://github.com/christophstrasen/lua-reactivex). Bring it in once:

```bash
git clone https://github.com/christophstrasen/lua-reactivex.git reactivex
# or: git submodule add https://github.com/christophstrasen/lua-reactivex.git reactivex
#      git submodule update --init --recursive
```

## Manual run

You can run the hook manually against all files:

```bash
pre-commit run --all-files
```
