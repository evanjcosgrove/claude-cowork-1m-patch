# claude-cowork-1m-patch

Restore 1M context windows in Claude Desktop's Cowork mode. Bypasses a server-side feature flag that silently downgraded Max plan subscribers from 1M to 200K context on March 19, 2026.



## The Problem

Feature flag `3885610113` controls whether the Cowork model resolution function appends `[1m]` to model names. On 2026-03-19, the flag was rolled back server-side — same app version, same session setup, different behavior. Log timestamps confirm the boundary: `18:36` `[1m]`, `19:59` no `[1m]`. The CLI was unaffected; only Desktop's `LocalAgentModeSessionManager` was broken.

17+ users reported it across GitHub issues [#37413](https://github.com/anthropics/claude-code/issues/37413), [#36760](https://github.com/anthropics/claude-code/issues/36760), [#36351](https://github.com/anthropics/claude-code/issues/36351), and [#33154](https://github.com/anthropics/claude-code/issues/33154) with no resolution after over a month of silence from Anthropic. Max subscribers ($200/month) are paying for 1M and getting 200K.

## Quick Start

```bash
./patch-claude-1m.sh
```

The script handles everything: backs up the original asar, patches the feature flag, updates all integrity hashes, and re-signs the app with preserved entitlements.

After it finishes, restart Claude Desktop and start a new Cowork session:

```bash
osascript -e 'quit app "Claude"'; sleep 3; open -a Claude
```

**Prerequisites:** Node.js, Python 3, macOS with Claude Desktop installed. The script auto-installs `@electron/asar` to a temp directory if it's not already available.

**What the script does not do:** The patch itself modifies only local files under `/Applications/Claude.app`. The script fetches `@electron/asar` from npm if it's not already installed, and reads no other network resources. No sudo required. Fully reversible via the backups on your Desktop.

## Root Cause

The Electron app's `app.asar` contains a model-resolution function with **two independent gates** that both must pass for `[1m]` to be appended:

```javascript
function ZAt(t) {
  return /\[1m\]/i.test(t) || !Sn("3885610113") || !/sonnet-4-6|opus-4-6/i.test(t)
    ? t
    : `${t}[1m]`
}
```

The ternary is a three-condition OR — if **any** is true, the model name is returned unchanged.

- **Gate A — Server feature flag.** `Sn("3885610113")` checks a server-side flag. When **off** (current state since 2026-03-19), `!Sn(...)` evaluates to `true`, the ternary short-circuits, and `[1m]` is never appended. You get 200K regardless of your plan.
- **Gate B — Model allow-list.** Even with the flag on, the regex `/sonnet-4-6|opus-4-6/i` only allows 1M for those two model names. When Anthropic shipped `claude-opus-4-7` to Cowork on 2026-04-18, the regex did **not** match it — so even an already-patched binary downgrades 4-7 sessions to 200K.

The patch addresses both gates with two same-length JS swaps. The function and variable names (`ZAt`, `Sn`, `A7e`, `Ti`, …) are minified and rotate between app versions. The flag ID `3885610113` is the stable Layer 1a anchor.

For Layer 1b, Anthropic refactored the gate from a regex to an array `.includes()` check around Claude Desktop v1.31xx. The script knows both byte anchors and detects which is present at runtime:

- **Form A (regex; older asars, ~v1.5xx and earlier):** anchor `sonnet-4-6|opus-4-6` → `opus-4-[67](?:)(?:)` (19-byte swap).
- **Form B (array; newer asars, ~v1.31xx+):** anchor `["claude-sonnet-4-6","claude-opus-4-6"]` → `[ "claude-opus-4-6","claude-opus-4-7" ]` (39-byte swap).

If neither anchor is present in either form, the script refuses to half-patch and exits with `unknown` — meaning Anthropic refactored the gate again and the script needs a Form C.

## Log Evidence


| Timestamp               | Event                                                                                                                                                                     |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 2026-03-18 06:51        | `[1m]` first observed in Cowork sessions                                                                                                                                  |
| 2026-03-19 18:36:58     | **Last working session** — `model: claude-opus-4-6[1m]`                                                                                                                   |
| 2026-03-19 19:59:08     | **First broken session** — `model: claude-opus-4-6` (same app version, flag rollback)                                                                                     |
| 2026-03-31 → 2026-04-06 | 110 consecutive sessions, all without `[1m]`                                                                                                                              |
| 2026-04-03 09:08        | Context window exceeded error — confirmed hitting 200K wall                                                                                                               |
| 2026-04-18 20:19:30     | Last working `opus-4-6[1m]` session under flag-bypass-only patch                                                                                                          |
| 2026-04-18 20:19:53     | **Second regression** — first `opus-4-7` session, no `[1m]`. Same app version (1.569.0), flag-bypass patch still installed. Model allow-list regex doesn't recognize 4-7. |


## How It Works

The patch modifies one JS expression in the asar, but the app enforces four integrity layers that all break when any file changes. Each layer must be updated in sequence:


| Layer                       | What it checks                                                       | How the patch handles it                                                                                                                                                                                                                 |
| --------------------------- | -------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **1. JS application logic** | Two gates in the model-resolution function: server feature flag + model allow-list (regex on older asars, JS array on newer asars). | **1a:** Replace `!Sn("3885610113")` with `!1/*___________*/` (same 17 bytes, evaluates to `false`). **1b:** Either `sonnet-4-6\|opus-4-6` → `opus-4-[67](?:)(?:)` (regex form, 19 bytes) or `["claude-sonnet-4-6","claude-opus-4-6"]` → `[ "claude-opus-4-6","claude-opus-4-7" ]` (array form, 39 bytes), depending on which anchor the asar contains. |
| **2. Per-file integrity**   | SHA256 of `index.js` in asar header                                  | Recompute file hash + block hashes, replace in header (same-length)                                                                                                                                                                      |
| **3. Header integrity**     | SHA256 of asar header in `Info.plist`                                | Recompute via `@electron/asar` `getRawHeader()`, write to plist                                                                                                                                                                          |
| **4. Code signature**       | macOS entitlements for Cowork's VM sandbox                           | Extract original entitlements before patching, re-sign with `--entitlements`                                                                                                                                                             |


The key constraint: all replacements must be **same-length**. Changing any file offset invalidates V8's compiled bytecode cache, causing `EXC_BREAKPOINT` crashes on launch. This rules out the obvious approach (extract the asar, edit the JS, repack) — repacking inflates the archive from 19MB to 60MB because native `.node` binaries get pulled in from `app.asar.unpacked`.

For the full technical deep-dive on each layer, see [docs/integrity-layers.md](docs/integrity-layers.md). For the reverse engineering process and the failed extract/repack attempt, see [docs/root-cause-analysis.md](docs/root-cause-analysis.md).

### Entitlements gotcha

After re-signing, Cowork may show "Invalid installation" if `com.apple.security.virtualization` is missing from the signature. This happens when you sign with `codesign --deep`, which re-signs inner frameworks and strips their original Anthropic signatures. The fix: sign **without** `--deep` and pass the original entitlements via `--entitlements`. The script handles this automatically by extracting entitlements before making any modifications.

## Caveats

- **Auto-updates overwrite the patch.** Re-run `./patch-claude-1m.sh` after each Claude Desktop update.
- **Minified names change between versions.** The script matches by stable byte anchors: the flag ID `3885610113` (Layer 1a), and one of two Layer 1b anchors depending on the asar version — `sonnet-4-6|opus-4-6` (regex form, older) or `["claude-sonnet-4-6","claude-opus-4-6"]` (array form, newer). Variable and function names (`ZAt`, `Sn`, `A7e`, `Ti`, …) are not relied on. When Anthropic refactors the gate again, expect to add a Form C.
- **Opus-only scope.** Layer 1b's new regex `opus-4-[67]` matches `opus-4-6` and `opus-4-7` only. The original regex also matched `sonnet-4-6` — that match is intentionally dropped so the rule is deterministic. If/when Anthropic ships `opus-4-8`, re-run the script after editing the 19-byte literal in the Layer 1b Python block of `patch-claude-1m.sh` (or open an issue).
- **This modifies the app binary.** The script creates a backup on every run. Fully reversible (see Rollback).
- **The `ANTHROPIC_DEFAULT_OPUS_MODEL` env var doesn't help.** `LocalAgentModeSessionManager` has its own model resolution path that ignores environment overrides.
- **ToS:** This is a personal workaround for a documented regression affecting paying customers. Use at your own risk.

## Rollback

Restore from the backup the script created on your Desktop:

```bash
cp ~/Desktop/app.asar.backup-YYYYMMDD-HHMMSS \
   /Applications/Claude.app/Contents/Resources/app.asar
cp ~/Desktop/Info.plist.backup-YYYYMMDD-HHMMSS \
   /Applications/Claude.app/Contents/Info.plist
osascript -e 'quit app "Claude"'; sleep 2; open -a Claude
```

## Related Issues

- [anthropics/claude-code#37413](https://github.com/anthropics/claude-code/issues/37413)
- [anthropics/claude-code#36760](https://github.com/anthropics/claude-code/issues/36760)
- [anthropics/claude-code#36351](https://github.com/anthropics/claude-code/issues/36351)
- [anthropics/claude-code#33154](https://github.com/anthropics/claude-code/issues/33154)

## Legal

This tool patches your local copy of Claude Desktop to restore functionality your subscription includes. It does not distribute Anthropic's code, bypass DRM or encryption, or access Anthropic's servers beyond the normal API calls your plan authorizes.
