# Contributing

Thanks for considering a contribution.

## Read this first

The [welcome post](https://github.com/evanjcosgrove/claude-cowork-1m-patch/discussions/1) covers where to post what, the bug-report checklist, and project cadence. Please skim it before opening an issue or PR.

## Where to file what

- **Usage questions** → [Q&A discussions](https://github.com/evanjcosgrove/claude-cowork-1m-patch/discussions/categories/q-a)
- **Bug reports / unrecognized Claude Desktop build** → [Issues](https://github.com/evanjcosgrove/claude-cowork-1m-patch/issues/new/choose) using the *Incompatible Claude Desktop build* template
- **Security issues** → see [SECURITY.md](SECURITY.md)
- **Code changes** → Pull request (see below)

## Pull requests

Especially welcome:

- **Form C support** when Anthropic refactors the model-resolution gate again - the script already auto-detects between Form A (regex) and Form B (array); see [CHANGELOG](CHANGELOG.md) for the precedent and [docs/integrity-layers.md](docs/integrity-layers.md) for the layer model.
- **New verified Claude Desktop versions** - please add a row to the Compatibility table in [README.md](README.md) with the date you tested.
- **Documentation fixes.**

For larger changes, please open an issue or discussion first so we can align on scope before you write code.

> [!IMPORTANT]
> Do **not** include patched binaries, raw `app.asar` files, or any Anthropic vendor code in PRs. Share only the minimal byte context needed to make the change reviewable (typically ~20 chars around any anchor).

## Code style

- Bash with `set -euo pipefail`.
- Inline Python via heredocs with positional argv (`<< 'PYEOF'`, no bash interpolation in the body).
- Same-length swaps for any new asar mutation - see [docs/integrity-layers.md](docs/integrity-layers.md) for why V8's bytecode cache makes this non-negotiable.
- Conventional commits: `type: description` (e.g. `fix:`, `feat:`, `docs:`).
- Idempotent: the script must be safe to re-run multiple times.

## Project cadence

No specific cadence; PRs that come with a tested Claude Desktop version and a clean preflight output land fastest.
