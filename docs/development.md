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

## Manual run

You can run the hook manually against all files:

```bash
pre-commit run --all-files
```
