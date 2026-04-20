# claude-cowork-1m-patch

Client-side patch to restore 1M context windows in Claude Desktop's Cowork mode. Neutralizes two JS gates inside the model-resolution function `ZAt`: the server feature flag `3885610113` and the `/sonnet-4-6|opus-4-6/i` model allow-list (broadened to also cover `opus-4-7`).

See [README.md](README.md) for full user-facing documentation.

## Project Structure

```
patch-claude-1m.sh          # Main patch script (bash) — the only executable
docs/root-cause-analysis.md # How the flag was found and the failed extract/repack approach
docs/integrity-layers.md    # The 4 integrity layers and their bypasses
```

No build step. Script self-installs `@electron/asar` (pinned to `4.2.0`, installed with `--ignore-scripts`) into a `mktemp -d` directory if it's not already present in the global or local `node_modules`.

## Running the Patch

```bash
./patch-claude-1m.sh
```

**Prerequisites:** Node.js, Python 3, macOS with Claude Desktop at `/Applications/Claude.app` (override with `CLAUDE_APP_PATH=/path/to/Claude.app`), plus `codesign` and `plutil` (Xcode CLT / macOS).

**Env overrides:**

- `CLAUDE_APP_PATH` — point at a non-default Claude.app bundle (e.g. a copy for testing).
- `ALLOW_PATCH_WITHOUT_ENTITLEMENTS=1` — skip the entitlements hard-fail. Cowork will likely show "Invalid installation" until entitlements are re-extracted, so this is an escape hatch, not a default.
- `PATCH_RESTORE_ON_FAIL=1` — on any non-zero exit *after* the backup is taken, automatically restore from that backup. Default behavior is to print the copy-pasteable restore command and let you decide.

**Verification:** Script prints `Layer 1a (feature flag): BYPASSED`, `Layer 1b (model allow-list): BROADENED`, and `Virtualization entitlement: PRESENT` on success. After relaunching Claude, new Cowork sessions on Opus 4.6 or 4.7 should show the `[1m]` suffix in `~/Library/Logs/Claude/cowork_vm_node.log`.

## Architecture Decisions

- **In-place binary patching** over extract/repack: Extracting the asar inflates it from 19MB to 60MB (native `.node` binaries get pulled from `app.asar.unpacked`), causing `EXC_BREAKPOINT` crashes from V8 bytecode cache offset mismatches.
- **Two same-length JS swaps** in the model-resolution function `ZAt`. Both must preserve byte length so V8's compiled bytecode cache stays valid.
  - **1a** `!Sn("3885610113")` → `!1/*___________*/` (17 bytes) — neutralizes the server feature flag.
  - **1b** `sonnet-4-6|opus-4-6` → `opus-4-[67](?:)(?:)` (19 bytes) — broadens the model allow-list to cover `opus-4-7` (April 18 regression). `(?:)(?:)` are zero-width non-capturing groups serving as 8 bytes of padding.
- **Idempotent state detection** via Python preflight, not raw `grep`. The preflight classifies the asar into one of `needs_1a` / `needs_1b` / `needs_both` / `already_done` / `unknown` using the same regex patterns as the patch blocks (so the matcher and the patcher cannot drift). `unknown` (neither unpatched anchors nor positive patched markers match) triggers a clear "open an issue with your app version" exit, instead of the old false-positive where any anchor-absent state was treated as "fully patched." Verification at the end re-runs the same matcher and requires `already_done`.
- **Atomic writes** for every asar mutation. Each Python heredoc that modifies `app.asar` writes to a same-directory `tempfile.mkstemp` file, calls `flush` + `os.fsync`, then `os.replace`s onto the asar — so a crash mid-write can never leave the asar half-written.
- **Single `EXIT` trap** (covers explicit `exit N`, `set -e` failures, and `INT`/`TERM` signals; disarms itself before exiting to avoid re-fire). After the backup step it surfaces a copy-pasteable rollback command on any failure, or auto-restores when `PATCH_RESTORE_ON_FAIL=1` is set.
- **Four integrity layers** must be updated in sequence: JS → per-file hash → header hash → code signature. Skipping any one causes launch failure. Layer 1 holds two JS gates; Layers 2–4 are unchanged.

## Non-obvious Gotchas

- **Minified variable names change between app versions.** Never search for `Sn` or `ZAt` — use the two stable byte anchors: flag ID `3885610113` (Layer 1a) and the literal regex body `sonnet-4-6|opus-4-6` (Layer 1b).
- **Both Layer 1a and Layer 1b enforce a unique-match check** (exactly one occurrence of the unpatched anchor before replacement). More than one match means the asar layout has changed in a way we don't understand — abort rather than guess.
- **Entitlements extraction is a hard-fail before backup.** If `codesign -d --entitlements` returns nothing, the script exits before touching anything. Bypass with `ALLOW_PATCH_WITHOUT_ENTITLEMENTS=1` only as a last resort — re-signing without entitlements strips `com.apple.security.virtualization` and Cowork breaks with "Invalid installation."
- **`codesign --deep` breaks Cowork.** It re-signs inner frameworks, stripping their original Anthropic signatures and the `com.apple.security.virtualization` entitlement. Always sign without `--deep` and with `--entitlements`.
- **Entitlements must be extracted BEFORE patching.** Once the binary is modified, `codesign -d --entitlements` returns the (now invalid) signature's entitlements.
- **`@electron/asar` is pinned to `4.2.0`** and installed with `--ignore-scripts` to defend against a future supply-chain landing a postinstall hook. Bump the pin intentionally and re-test — a silent transitive change in the header parser would silently corrupt the patch.
- **Temp paths use `mktemp` / `mktemp -d`.** Don't introduce predictable `/tmp/...` paths — they're a symlink-attack vector on a multi-user machine.
- **Auto-updates overwrite the patch.** Users must re-run after each Claude Desktop update.
- **`ANTHROPIC_DEFAULT_OPUS_MODEL` env var does NOT work** for Cowork — `LocalAgentModeSessionManager` has its own model resolution path that ignores environment overrides.

## Code Style

- Bash with `set -euo pipefail`. Inline Python for binary manipulation (regex on raw bytes), passed via heredoc with positional argv (no bash expansion in Python bodies — heredocs are `<< 'PYEOF'`).
- Bash gotcha: do **not** wrap `$(python3 ... << 'PYEOF' ... PYEOF)` in outer double quotes (`"$(...)"`). The bash parser miscounts apostrophes inside the heredoc body when the substitution is double-quoted. Use bare `X=$(...)` for assignments — no word-splitting risk on the RHS of an assignment.
- Conventional commits: `type: description` (e.g., `feat:`, `fix:`, `docs:`).
- Keep the patch script idempotent — safe to run multiple times.

## Related GitHub Issues

- anthropics/claude-code#37413, #36760, #36351, #33154
