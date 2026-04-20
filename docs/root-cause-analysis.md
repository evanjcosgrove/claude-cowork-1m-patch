# Root Cause Analysis: Enabling 1M Context in Claude Desktop

How the feature flag was identified, why the obvious extract/repack approach fails, and how in-place binary patching works around V8's bytecode cache constraints.

## Finding the Feature Flag

Searched for flag ID `3885610113` across extracted JS files. Found it in `.vite/build/index.js` line 4407.

The minified function name was `ZAt` with flag checker `Sn`. Previous builds used `GEe`/`Vr` — minified names change between builds. The flag ID `3885610113` is the stable anchor to locate the relevant code across versions.

## Understanding the Logic

The relevant ternary in minified JS:

```js
return /\[1m\]/i.test(t) || !Sn("3885610113") || !/sonnet-4-6|opus-4-6/i.test(t) ? t : `${t}[1m]`
```

Three OR conditions. If **any** is true, return the model name unchanged. If **all** are false, append `[1m]`.

When the server-side flag is OFF: `!Sn("3885610113")` evaluates to `true` → short-circuits → `[1m]` is never appended → 200K context window.

## The Failed Extract/Repack Attempt

First approach: `npx @electron/asar extract` → modify → `npx @electron/asar pack`.

The asar ballooned from 19MB to 60MB. `extract` pulls files from `app.asar.unpacked` into the extraction directory. Repacking included native `.node` binaries that are supposed to remain external.

Result: `EXC_BREAKPOINT (SIGTRAP)` crash 224ms after launch during `node::sea::SeaResource::use_code_cache()`. V8's compiled bytecode cache expected specific file offsets that no longer matched.

## Discovering In-Place Binary Patching

Instead of extract/repack, directly modify bytes in the asar file.

Replace `!Sn("3885610113")` (17 bytes) with `!1/*___________*/` (17 bytes — JS comment padding to maintain exact length). Zero change to file offsets, header, or structure. V8's bytecode cache offsets remain valid.

## The ASAR Integrity Wall

After binary patching, the app refused to launch:

```
ASAR Integrity Violation: got a hash mismatch
```

Per-file SHA256 hashes are stored in the asar's JSON header. Also per-4MB-block hashes. Updated both, then hit the `ElectronAsarIntegrity` key in `Info.plist` which stores the SHA256 of the raw asar header string. Updated that too.

## The Entitlements Gotcha

After bypassing all integrity checks, the app launched but showed:

```
Invalid installation — Claude's installation appears to be corrupted.
```

Traced to `require("@ant/claude-swift").vm.isVirtualizationSupported()` returning `"entitlement_missing"`. The `codesign --force --deep --sign -` invocation had stripped the `com.apple.security.virtualization` entitlement.

Fix: extract entitlements **before** patching, then re-sign with `--entitlements <file>` (without `--deep`).

`--deep` re-signs inner frameworks and strips their original Anthropic signatures. Omitting `--deep` preserves inner framework signatures while only re-signing the outer bundle.

## April 18 2026 — Second Gate Discovered

Five weeks after the initial flag-bypass patch shipped, a fresh log review surfaced a 23-second boundary in `cowork_vm_node.log`:

| Timestamp | Spawn line |
|---|---|
| 2026-04-18 20:19:30 | `--model claude-opus-4-6[1m]` (last working) |
| 2026-04-18 20:19:53 | `--model claude-opus-4-7` (no `[1m]`) |

Same patched binary, same session, two different models — only the second was downgraded. Anthropic had silently shipped `opus-4-7` to Cowork without re-enabling 1M for it.

Inspecting the live `ZAt` function in the patched asar showed a second gate:

```javascript
function ZAt(t) {
  return /\[1m\]/i.test(t) || !1/*___________*/ || !/sonnet-4-6|opus-4-6/i.test(t)
    ? t : `${t}[1m]`
}
```

Layer 1a was correctly neutralized (`!1/*___________*/` evaluates to `false`). But the third condition's regex `/sonnet-4-6|opus-4-6/i` doesn't match `opus-4-7`, so `!regex.test('claude-opus-4-7')` evaluates to `true`, the ternary short-circuits, and `[1m]` is never appended.

The fix is the same shape as Layer 1a: a same-length swap of the regex body. `sonnet-4-6|opus-4-6` is 19 bytes; `opus-4-[67](?:)(?:)` is 19 bytes and matches `opus-4-6` and `opus-4-7` only — the two `(?:)` empty non-capturing groups are zero-width padding that round out the byte budget without affecting matching semantics.

The original four-layer integrity model is unchanged. Layer 1 just turned out to have two same-length JS gates instead of one. Same V8 bytecode cache constraint, same per-file/header SHA256 recomputation, same re-sign — Layer 1b is a 15-line addition to the existing patch script.
