# claude-cowork-1m-patch

Client-side patch to restore 1M context windows in Claude Desktop's Cowork mode after Anthropic's March 19, 2026 feature flag rollback.

## The Problem

Since March 19, 2026, Max plan users have been silently downgraded from 1M to 200K context in Cowork mode. The Claude Code CLI continued working at 1M throughout — the regression is isolated to the Claude Desktop Electron app's model resolution path.

- 17+ affected users across GitHub issues [#37413](https://github.com/anthropics/claude-code/issues/37413), [#36760](https://github.com/anthropics/claude-code/issues/36760), [#36351](https://github.com/anthropics/claude-code/issues/36351)
- Zero Anthropic response for 17+ days
- Max 20x plan customers paying for 1M context, receiving 200K

## Root Cause

The Electron app's `app.asar` contains a model resolution function that gates 1M context behind a server-side feature flag:

```javascript
// In .vite/build/index.js (minified — function/var names vary by version)
function ZAt(t) {
  return /\[1m\]/i.test(t) || !Sn("3885610113") || !/sonnet-4-6|opus-4-6/i.test(t)
    ? t
    : `${t}[1m]`
}
```

- `Sn("3885610113")` checks feature flag ID `3885610113` server-side
- Flag **ON**: appends `[1m]` to `opus-4-6`/`sonnet-4-6` model names → **1M context**
- Flag **OFF** (current state since ~March 19): `!Sn(...)` is `true`, ternary short-circuits, `[1m]` never appended → **200K context**
- The first clause `/\[1m\]/i.test(t)` is a passthrough guard to prevent double-appending

The `[1m]` suffix is a client-side model identifier that signals the API to allocate 1M context. Without it, you get 200K regardless of your plan.

## Log Evidence

| Timestamp | Event |
|-----------|-------|
| 2026-03-18 06:51 | `[1m]` first observed in Cowork sessions |
| 2026-03-19 18:36:58 | **Last working session** — `model: claude-opus-4-6[1m]` |
| 2026-03-19 19:59:08 | **First broken session** — `model: claude-opus-4-6` (same app version, flag rollback) |
| 2026-03-31 → 2026-04-06 | 110 consecutive sessions, all `claude-opus-4-6` without `[1m]` |
| 2026-04-03 09:08 | Context window exceeded error — confirmed hitting 200K wall |

## Quick Start

```bash
# 1. Back up the original
cp /Applications/Claude.app/Contents/Resources/app.asar \
   ~/Desktop/app.asar.backup-$(date +%Y%m%d-%H%M%S)

# 2. Run the patch script
./patch-claude-1m.sh

# 3. Restart Claude Desktop
osascript -e 'quit app "Claude"'; sleep 3; open -a Claude
```

**Prerequisites:** Node.js, `@electron/asar` (`npm install -g @electron/asar`), Python 3

## How It Works — The 4-Layer Bypass

The app has four integrity layers that must all be updated after patching the JS.

| Layer | What it checks | Bypass |
|-------|---------------|--------|
| 1. JS feature flag | `!Sn("3885610113")` server-side flag check | Replace with `!1/*___________*/` (same 17 bytes, in-place) |
| 2. Per-file integrity | SHA256 of `index.js` stored in asar header | Recompute file hash + changed block hash, replace in header |
| 3. Header integrity | SHA256 of asar header stored in `Info.plist` | Recompute via `@electron/asar` `getRawHeader()`, write to plist |
| 4. Code signature | macOS entitlements (Cowork VM needs `com.apple.security.virtualization`) | Extract original entitlements, re-sign with `--entitlements` |

### Layer 1: JS Feature Flag

The patch is a same-length binary replacement — no asar extract/repack needed:

- **Old:** `!Sn("3885610113")` — 17 bytes, calls flag check
- **New:** `!1/*___________*/` — 17 bytes, always returns `false`

The minified variable name (`Sn`) changes between app versions. The flag ID `3885610113` is stable — search for that, not the variable name. The patch script handles variant detection automatically.

### Layer 2: Per-File Integrity Hashes

The asar header contains a SHA256 hash of `index.js` and SHA256 hashes of each 4MB block. After patching the JS, these must be recomputed and replaced in the header. Because hashes are 64 hex characters, this is again a same-length in-place replacement.

### Layer 3: Info.plist Header Hash

`/Applications/Claude.app/Contents/Info.plist` contains a `ElectronAsarIntegrity` key with a SHA256 hash of the entire asar header. After updating the header hashes in layer 2, this hash is stale and must be recomputed using `@electron/asar`'s `getRawHeader()` and written back via `plutil`.

### Layer 4: Code Signature (Entitlements)

After any modification, the macOS code signature is invalid. Re-signing with `codesign --force --sign -` works, but **two flags are critical:**

- `--entitlements /tmp/claude-entitlements.plist` — **required.** Without this, `com.apple.security.virtualization` is stripped from the signature, and Cowork shows "Invalid installation" because it cannot access the Virtualization framework for its VM sandbox.
- Do **not** use `--deep` — that re-signs inner frameworks and strips Anthropic's original signatures on those binaries.

Entitlements must be extracted from the **original, unmodified** binary before patching:

```bash
codesign -d --entitlements :/tmp/claude-entitlements.plist /Applications/Claude.app
```

### What to expect after patching

- Cowork sessions will spawn with `--model claude-opus-4-6[1m]`
- The `model_configs/claude-opus-4-6[1m]` API endpoint may return 404 — this is non-critical, the model falls back to base config
- Rate limits may be reached faster since 1M context consumes more quota per turn

## Caveats

- **Auto-updates overwrite the patch.** Re-run `patch-claude-1m.sh` after each Claude Desktop update.
- **Minified names change between versions.** The flag ID `3885610113` is the stable anchor — the script searches by flag ID, not by `Sn` or `ZAt`.
- **This modifies the app binary.** Keep the backup. The patch is fully reversible (see Rollback).
- **ToS:** This is a personal workaround for a documented regression affecting paying customers. Use at your own risk.

## Rollback

```bash
cp ~/Desktop/app.asar.backup-YYYYMMDD-HHMMSS \
   /Applications/Claude.app/Contents/Resources/app.asar
osascript -e 'quit app "Claude"'; sleep 2; open -a Claude
```

## Related Issues

- [#37413](https://github.com/anthropics/claude-code/issues/37413)
- [#36760](https://github.com/anthropics/claude-code/issues/36760)
- [#36351](https://github.com/anthropics/claude-code/issues/36351)
- [#33154](https://github.com/anthropics/claude-code/issues/33154)

**Note:** The `ANTHROPIC_DEFAULT_OPUS_MODEL` environment variable workaround does not affect Cowork — `LocalAgentModeSessionManager` has its own model resolution path that ignores environment overrides.
