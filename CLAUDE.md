# claude-cowork-1m-patch

Client-side patch to restore 1M context windows in Claude Desktop's Cowork mode. Bypasses server-side feature flag `3885610113` that gates the `[1m]` model suffix.

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

**Verification:** Script prints `Feature flag: BYPASSED` and `Virtualization entitlement: PRESENT` on success. After relaunching Claude, new Cowork sessions should show `Opus 4.6 Extended` or `claude-opus-4-6[1m]`.

## Architecture Decisions

- **In-place binary patching** over extract/repack: Extracting the asar inflates it from 19MB to 60MB (native `.node` binaries get pulled from `app.asar.unpacked`), causing `EXC_BREAKPOINT` crashes from V8 bytecode cache offset mismatches.
- **Same-length replacement** (`!Sn("3885610113")` → `!1/*___________*/`): Preserves all file offsets so V8's compiled bytecode cache remains valid.
- **Four integrity layers** must be updated in sequence: JS → per-file hash → header hash → code signature. Skipping any one causes launch failure.

## Non-obvious Gotchas

- **Minified variable names change between app versions.** Never search for `Sn` or `ZAt` — use the flag ID `3885610113` as the stable anchor.
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
