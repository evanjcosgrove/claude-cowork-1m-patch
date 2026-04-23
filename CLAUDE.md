# claude-cowork-1m-patch

Client-side patch to restore 1M context windows in Claude Desktop's Cowork mode. Neutralizes two JS gates in the model-resolution function: the server feature flag `3885610113` and a model allow-list (broadened to cover `opus-4-7`).

See [README.md](README.md) for full user-facing documentation.

## Project Structure

```
patch-claude-1m.sh          # Main patch script (bash) - the only executable
docs/root-cause-analysis.md # How the flag was found and the failed extract/repack approach
docs/integrity-layers.md    # The 4 integrity layers and their bypasses
```

No build step. Script self-installs `@electron/asar` (pinned to `4.2.0`, installed with `--ignore-scripts`) into a `mktemp -d` directory if it's not already present in the global or local `node_modules`.

## Running the Patch

See [README.md § Before You Run](README.md#before-you-run) for prerequisites and verification. This file captures only things that matter when *modifying* the script.

## Architecture Decisions

- **In-place binary patching** over extract/repack. Extract/repack inflates the asar from 19MB→60MB (native `.node` binaries get pulled from `app.asar.unpacked`) and crashes V8 on launch with `EXC_BREAKPOINT` from bytecode-cache offset mismatches. Every asar mutation in this script must preserve byte length.
- **Two same-length JS swaps** neutralize the model-resolution gates. Layer 1a swaps the flag check; Layer 1b swaps the model allow-list and exists in two forms (regex for < v1.3109, JS array for ≥ v1.3109) auto-detected by preflight. Full byte spec: [docs/integrity-layers.md § Layer 1](docs/integrity-layers.md#layer-1---application-logic-two-js-gates).
- **Idempotent state detection** via Python preflight, not raw `grep`. Classifies the asar into `needs_1a` / `needs_1b` / `needs_both` / `already_done` / `unknown` AND detects which Layer 1b form is present, using the *same* byte anchors as the patch blocks so the matcher and the patcher cannot drift. `unknown` (including "Layer 1a anchor present but Layer 1b form unrecognized") aborts rather than half-patches. Verification at the end re-runs the matcher and requires `already_done`.
- **Atomic writes** for every asar mutation. Python heredocs write to a same-directory `tempfile.mkstemp`, `flush` + `fsync`, then `os.replace` - a crash mid-write can never leave the asar half-written.
- **Single `EXIT` trap** covers explicit `exit N`, `set -e` failures, and `INT`/`TERM`; disarms itself before exiting to avoid re-fire. After the backup step, it surfaces a copy-pasteable rollback command on failure, or auto-restores when `PATCH_RESTORE_ON_FAIL=1`.
- **Four integrity layers** must be updated in sequence: JS → per-file hash → header hash → code signature. Skipping one causes launch failure. Layer 1 holds two JS gates; Layers 2–4 are unchanged between versions.

## Non-obvious Gotchas

- **Never search for minified names** (`Sn` / `Ti` / `ZAt` / `A7e`) - they rotate between app versions. Anchor on the flag ID and Layer 1b form strings (see integrity-layers.md).
- **Layer 1b form rotation is a silent-failure mode.** When the model gate was refactored regex→array in v1.3109, older scripts that only knew the regex anchor detected `needs_1a` only, half-patched, and failed verification. The current preflight refuses to proceed (`unknown`) when Layer 1a's anchor is present but Layer 1b's form is unrecognized. When the gate is refactored again, add a Form C alongside A/B in the preflight + patch-dispatch - don't paper over it.
- **Both Layer 1a and Layer 1b enforce a unique-match check** (exactly one occurrence of the unpatched anchor). More than one means the asar layout changed in a way we don't understand - abort rather than guess.
- **Entitlements extraction is a hard-fail before backup.** If `codesign -d --entitlements` returns nothing, exit before touching anything. `ALLOW_PATCH_WITHOUT_ENTITLEMENTS=1` is a last-resort escape hatch - re-signing without entitlements strips `com.apple.security.virtualization` and Cowork breaks with "Invalid installation."
- **Never use `codesign --deep`.** It re-signs inner frameworks, stripping their original Anthropic signatures and the virtualization entitlement. Sign without `--deep` and with `--entitlements`.
- **Entitlements must be extracted BEFORE patching.** Once the binary is modified, `codesign -d --entitlements` returns the (now invalid) signature's entitlements.
- **`@electron/asar` is pinned to `4.2.0`** and installed with `--ignore-scripts` to defend against a future supply-chain postinstall hook. Bump the pin intentionally and re-test - a silent transitive change in the header parser would silently corrupt the patch.
- **Temp paths use `mktemp` / `mktemp -d`** - never predictable `/tmp/...` paths (symlink-attack vector on a multi-user machine).
- **`ANTHROPIC_DEFAULT_OPUS_MODEL` does NOT affect Cowork.** `LocalAgentModeSessionManager` has its own model resolution path that ignores environment overrides.

## Code Style

- Bash with `set -euo pipefail`. Inline Python via heredocs with positional argv (`<< 'PYEOF'`, no bash interpolation in the body).
- **Heredoc gotcha:** do not wrap `$(python3 ... << 'PYEOF' ... PYEOF)` in outer double quotes - bash miscounts apostrophes inside double-quoted heredoc substitutions. Use bare `X=$(...)` assignments (no word-splitting on the RHS of an assignment).
- Same-length swaps for any new asar mutation - V8 bytecode-cache constraint.
- Idempotent: the script must be safe to re-run.
- Conventional commits: `type: description` (`feat:`, `fix:`, `docs:`).
