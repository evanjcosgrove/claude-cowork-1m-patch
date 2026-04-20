# Integrity Layers: Claude Desktop on macOS

Four distinct integrity mechanisms protect the app. All four must be addressed for a successful patch.

---

## Layer 1 — Application Logic (Two JS Gates)

The model-resolution function `ZAt` contains a three-condition OR ternary. Two of the three conditions act as gates that block the `[1m]` suffix from being appended. Both must be neutralized.

```javascript
function ZAt(t) {
  return /\[1m\]/i.test(t) || !Sn("3885610113") || !/sonnet-4-6|opus-4-6/i.test(t)
    ? t : `${t}[1m]`
}
```

### Bypass 1a — Server feature flag

**What:** `!Sn("3885610113")` performs a server-side feature flag check at runtime. When the flag is off, this evaluates to `true` and short-circuits the ternary.

**Bypass:** Same-length replacement using a JS comment to pad to exactly 17 bytes:

```
Before: !Sn("3885610113")       // 17 bytes
After:  !1/*___________*/       // 17 bytes
```

**Result:** Gate 1a always evaluates to `false`. The flag check is neutralized.

### Bypass 1b — Model allow-list

Anthropic refactored this gate around Claude Desktop v1.3109. The script auto-detects which form the asar uses and dispatches the matching same-length swap; if neither form is recognized, preflight exits `unknown` rather than half-patch.

#### Form A — regex literal (Claude Desktop < v1.3109)

**What:** `!/sonnet-4-6|opus-4-6/i.test(t)` rejects any model name that isn't `sonnet-4-6` or `opus-4-6`. When Anthropic added `claude-opus-4-7` to Cowork on 2026-04-18, this gate started returning `true` for 4-7 sessions, downgrading them to 200K even on a binary patched only at Gate 1a.

**Bypass:** Same-length swap of the regex body (the literal `sonnet-4-6|opus-4-6` is the byte anchor; the surrounding `/.../i` delimiters are left untouched):

```
Before: sonnet-4-6|opus-4-6     // 19 bytes — matches sonnet-4-6, opus-4-6
After:  opus-4-[67](?:)(?:)     // 19 bytes — matches ONLY opus-4-6, opus-4-7
```

`opus-4-[67]` is the productive 11-byte payload; `(?:)(?:)` is two zero-width non-capturing groups serving as 8 bytes of pure padding. The replacement is a valid regex body whose semantics are exactly: "any string containing `opus-4-6` or `opus-4-7`."

**Result:** Gate 1b returns `false` for both `claude-opus-4-6` and `claude-opus-4-7`. The function falls through to `${t}[1m]` and 1M context is requested. `sonnet-4-6` no longer matches — that drop is intentional (see README "Opus-only scope" caveat).

#### Form B — JS array (Claude Desktop ≥ v1.3109)

**What:** Anthropic refactored the regex literal into a JS array used with `.some(t => e.includes(t))` substring matching:

```javascript
const eyn = ["claude-sonnet-4-6", "claude-opus-4-6"];
function A7e(t) {
  return /\[1m\]/i.test(t) || !Ti("3885610113") || !(e0t() ?? eyn).some(s => t.includes(s))
    ? t : `${t}[1m]`
}
```

`e0t()` reads a server-pushed allow-list (from `pB().supports1mContext`); when the server hasn't delivered one — the dominant case at session-construction time — `??` falls through to the local `eyn` array. The patch swaps the local array.

**Bypass:** Same-length swap of the array literal:

```
Before: ["claude-sonnet-4-6","claude-opus-4-6"]   // 39 bytes
After:  [ "claude-opus-4-6","claude-opus-4-7" ]   // 39 bytes
```

Whitespace inside the brackets pads the byte budget; `claude-sonnet-4-6` is intentionally dropped (per the "Opus-only scope" caveat) and `claude-opus-4-7` is added so the next regression doesn't require another script update.

**Result:** `.includes()` matches `claude-opus-4-6` and `claude-opus-4-7`. The function falls through to `${t}[1m]` and 1M context is requested.

### Why same-length is non-negotiable

V8 caches compiled JS bytecode against the asar's file offsets. Any change to byte length shifts every offset after the change point, invalidating the cache and producing `EXC_BREAKPOINT (SIGTRAP)` on launch. Both swaps preserve the surrounding byte layout exactly.

---

## Layer 2 — File Integrity (Per-file SHA256 in ASAR Header)

**What:** Each file in the asar has a SHA256 hash and per-4MB-block hashes stored in the asar's JSON header.

**Where:** In the asar header JSON:

```json
{
  "algorithm": "SHA256",
  "hash": "4db764d5...",
  "blockSize": 4194304,
  "blocks": ["a1b2c3...", "..."]
}
```

**Bypass:** Compute the new SHA256 of the patched file using `@electron/asar`'s `extractFile` + `crypto.createHash`. Replace the old 64-hex-char hash with the new 64-hex-char hash (same length, in-place in the header).

**Prior art:** CVE-2024-46992 (ASAR integrity bypass via header manipulation — Electron's advisory scopes the vulnerability to Windows under specific fuse configurations; cited here for the same general integrity-layer pattern, not as a claim that Claude Desktop on macOS was affected by that specific CVE); CVE-2025-55305 (ASAR integrity bypass via V8 heap snapshot resource modification, affecting Signal, 1Password, Slack); Karol Mazurek's "Cracking Electron Integrity."

---

## Layer 3 — Archive Integrity (Header SHA256 in Info.plist)

**What:** `ElectronAsarIntegrity` in `Info.plist` stores the SHA256 of the raw asar header string.

**Where:** `/Applications/Claude.app/Contents/Info.plist`

```xml
<key>ElectronAsarIntegrity</key>
<dict>
  <key>Resources/app.asar</key>
  <dict>
    <key>algorithm</key>
    <string>SHA256</string>
    <key>hash</key>
    <string><!-- SHA256 of raw header string --></string>
  </dict>
</dict>
```

**Bypass:** Recompute via `@electron/asar`'s `getRawHeader()` + `crypto.createHash('sha256')`. Update the plist value with `plutil -replace`.

**Prior art:** Electron docs explicitly describe this mechanism as a tamper-detection layer.

---

## Layer 4 — Platform Integrity (macOS Code Signature + Entitlements)

**What:** macOS code signature with the `com.apple.security.virtualization` entitlement, required for Cowork's VM sandbox (`@ant/claude-swift`).

**Where:** Embedded in the app's code signature, readable via:

```sh
codesign -d --entitlements - /Applications/Claude.app
```

**Bypass:**

1. Extract entitlements **before** patching:
   ```sh
   codesign -d --entitlements entitlements.plist /Applications/Claude.app
   ```
2. After patching, re-sign with the preserved entitlements:
   ```sh
   codesign --force --sign - --entitlements entitlements.plist /Applications/Claude.app
   ```

**Key insight:** Do **not** use `--deep`. The `--deep` flag re-signs inner frameworks and strips their original Anthropic signatures. Without `--deep`, only the outer bundle is re-signed, preserving inner framework signatures and all original entitlements.
