# Integrity Layers: Claude Desktop on macOS

Four distinct integrity mechanisms protect the app. All four must be addressed for a successful patch.

---

## Layer 1 — Application Logic (JS Feature Flag)

**What:** `!Sn("3885610113")` performs a server-side feature flag check at runtime.

**Bypass:** Same-length replacement using a JS comment to pad to exactly 17 bytes:

```
Before: !Sn("3885610113")       // 17 bytes
After:  !1/*___________*/       // 17 bytes
```

**Result:** Flag always evaluates to `false`. The context-append function always appends `[1m]`, enabling 1M context for `sonnet-4-6` and `opus-4-6` regardless of server flag state.

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

**Prior art:** CVE-2024-46992 (ASAR integrity bypass via header manipulation); CVE-2025-55305 (ASAR integrity bypass via V8 heap snapshot resource modification, affecting Signal, 1Password, Slack); Karol Mazurek's "Cracking Electron Integrity."

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
