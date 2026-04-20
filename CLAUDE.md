# claude-cowork-1m-patch

Client-side patch to restore 1M context windows in Claude Desktop's Cowork mode. Neutralizes two JS gates inside the model-resolution function `ZAt`: the server feature flag `3885610113` and the `/sonnet-4-6|opus-4-6/i` model allow-list (broadened to also cover `opus-4-7`).

See [README.md](README.md) for full user-facing documentation.

## Project Structure

```
patch-claude-1m.sh          # Main patch script (bash) — the only executable
docs/root-cause-analysis.md # How the flag was found and the failed extract/repack approach
docs/integrity-layers.md    # The 4 integrity layers and their bypasses
```

No build step, no dependencies to install (script self-installs `@electron/asar` to `/tmp` if missing).

## Running the Patch

```bash
./patch-claude-1m.sh
```

**Prerequisites:** Node.js, Python 3, macOS with Claude Desktop at `/Applications/Claude.app`.

**Verification:** Script prints `Layer 1a (feature flag): BYPASSED`, `Layer 1b (model allow-list): BROADENED`, and `Virtualization entitlement: PRESENT` on success. After relaunching Claude, new Cowork sessions on Opus 4.6 or 4.7 should show the `[1m]` suffix in `~/Library/Logs/Claude/cowork_vm_node.log`.

## Architecture Decisions

- **In-place binary patching** over extract/repack: Extracting the asar inflates it from 19MB to 60MB (native `.node` binaries get pulled from `app.asar.unpacked`), causing `EXC_BREAKPOINT` crashes from V8 bytecode cache offset mismatches.
- **Two same-length JS swaps** in the model-resolution function `ZAt`. Both must preserve byte length so V8's compiled bytecode cache stays valid.
  - **1a** `!Sn("3885610113")` → `!1/*___________*/` (17 bytes) — neutralizes the server feature flag.
  - **1b** `sonnet-4-6|opus-4-6` → `opus-4-[67](?:)(?:)` (19 bytes) — broadens the model allow-list to cover `opus-4-7` (April 18 regression). `(?:)(?:)` are zero-width non-capturing groups serving as 8 bytes of padding.
- **Idempotent state detection** by byte anchor: the script greps for `3885610113` and `sonnet-4-6|opus-4-6` independently, applies only the missing layer(s), and exits cleanly when both anchors are absent. Users with only Layer 1a applied get just the missing Layer 1b update.
- **Four integrity layers** must be updated in sequence: JS → per-file hash → header hash → code signature. Skipping any one causes launch failure. Layer 1 holds two JS gates; Layers 2–4 are unchanged.

## Non-obvious Gotchas

- **Minified variable names change between app versions.** Never search for `Sn` or `ZAt` — use the two stable byte anchors: flag ID `3885610113` (Layer 1a) and the literal regex body `sonnet-4-6|opus-4-6` (Layer 1b).
- **`codesign --deep` breaks Cowork.** It re-signs inner frameworks, stripping their original Anthropic signatures and the `com.apple.security.virtualization` entitlement. Always sign without `--deep` and with `--entitlements`.
- **Entitlements must be extracted BEFORE patching.** Once the binary is modified, `codesign -d --entitlements` returns the (now invalid) signature's entitlements.
- **Auto-updates overwrite the patch.** Users must re-run after each Claude Desktop update.
- **`ANTHROPIC_DEFAULT_OPUS_MODEL` env var does NOT work** for Cowork — `LocalAgentModeSessionManager` has its own model resolution path that ignores environment overrides.

## Code Style

- Bash with `set -euo pipefail`. Inline Python for binary manipulation (regex on raw bytes).
- Conventional commits: `type: description` (e.g., `feat:`, `fix:`, `docs:`).
- Keep the patch script idempotent — safe to run multiple times.

## Related GitHub Issues

- anthropics/claude-code#37413, #36760, #36351, #33154
