# Changelog

All notable changes to `patch-claude-1m.sh`. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Each entry tracks a specific Claude Desktop change that required (or was unlocked by) a patch update. If you're already running the latest script, you only need to re-run it after a Claude Desktop auto-update; this log is here to help you decide whether that re-run will actually fix anything for you.

## 2026-04-20

- **Added:** Layer 1b form-detection (regex vs array vs none). The preflight now dispatches the matching same-length swap, and refuses to half-patch when neither form is recognized.
- **Why:** Claude Desktop **v1.3109.0** (released 2026-04-16) refactored the model-allow-list gate from a regex literal (`/sonnet-4-6|opus-4-6/i`) to a JS array (`["claude-sonnet-4-6","claude-opus-4-6"]`) used with `.some(t => e.includes(t))`. The old anchor was absent in the new asar; the prior script's preflight half-patched and verification failed, leaving the asar with Layer 1a applied and Layer 1b untouched.
- **Action required:** Re-run `./patch-claude-1m.sh` if you're on Claude Desktop ≥ v1.3109. Older asars are unaffected - the script auto-detects which form your asar uses.
- **Reference:** [docs/root-cause-analysis.md § April 19–20 2026 - Form B Discovered](docs/root-cause-analysis.md)

## 2026-04-18

- **Added:** Layer 1b - model allow-list broadened to also cover `claude-opus-4-7`.
- **Why:** Anthropic shipped `claude-opus-4-7` to Cowork. Layer 1a (server flag bypass) alone was not enough - the model-allow-list regex `/sonnet-4-6|opus-4-6/i` rejected 4-7 sessions, so `[1m]` was never appended. Same-length swap of the regex body to `opus-4-[67](?:)(?:)`. `sonnet-4-6` intentionally dropped (see "Opus-only scope" caveat in [README.md](README.md)).
- **Action required:** Re-run `./patch-claude-1m.sh`.
- **Reference:** [docs/root-cause-analysis.md § April 18 2026 - Second Gate Discovered](docs/root-cause-analysis.md)

## 2026-03-19

- **Added:** Initial Layer 1a - server feature-flag bypass. Same-length swap of `!Sn("3885610113")` → `!1/*___________*/` (17 bytes). Plus the four-layer integrity flow: per-file SHA256, header SHA256 in `Info.plist`, codesign with preserved entitlements.
- **Why:** Anthropic rolled back feature flag `3885610113` server-side, silently downgrading Cowork sessions from a 1M to a 200K context window without any client-side code change. Same Claude Desktop version, different server state.
- **Reference:** [README.md § Root Cause](README.md#root-cause-deep-dive), [docs/root-cause-analysis.md](docs/root-cause-analysis.md), [docs/integrity-layers.md](docs/integrity-layers.md)
