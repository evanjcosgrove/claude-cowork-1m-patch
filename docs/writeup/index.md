---
layout: page
title: Restoring 1M context in Claude Desktop's Cowork mode
---

*Code: [github.com/evanjcosgrove/claude-cowork-1m-patch](https://github.com/evanjcosgrove/claude-cowork-1m-patch)*

Two Cowork sessions, ninety minutes apart, same Claude Desktop install. The 18:36 session had a 1M-token context window. The 19:59 session had 200K. Nothing on my end had changed.

I checked the logs. The earlier session's spawn line ended in `--model claude-opus-4-6[1m]`. The later one ended in `--model claude-opus-4-6` — same model name, no `[1m]` suffix. Same app version (1.569.0). Same Max plan. Same shell, same network, same everything.

Whatever had changed wasn't on my machine. It was something Claude Desktop had asked the server about, somewhere between 18:36 and 19:59 on March 19, 2026, and the server had said no.

Cowork is Claude Desktop's local-agent mode — a sandboxed VM that runs Claude Code with skills, plugins, and file mounts. The 1M-token context window is the headline Max-plan feature for the kind of long-session refactoring work I'd been using it for; dropping to 200K means losing the ability to hold a whole codebase in mind. I [filed an issue](https://github.com/anthropics/claude-code/issues/37413), found 16 others doing the same across [#36760](https://github.com/anthropics/claude-code/issues/36760), [#36351](https://github.com/anthropics/claude-code/issues/36351), and [#33154](https://github.com/anthropics/claude-code/issues/33154), and watched them sit untouched for thirty days. So I went looking for it myself.

My first guess was that something on the client side was passing the wrong model identifier. The CLI version of Claude Code reads `ANTHROPIC_DEFAULT_OPUS_MODEL` from the environment to pick which model to invoke; setting it to `claude-opus-4-6[1m]` made the CLI work fine. But Cowork didn't care. The model picker in the Desktop UI showed the right options, and selecting `Opus 4.6 Extended` produced sessions whose spawn arguments still lacked the `[1m]` suffix.

That ruled out the easy fixes. Whatever was deciding the model identifier in Cowork wasn't reading the same environment variable the CLI did, and it wasn't honoring the UI selection in the way I expected. The model resolution was happening somewhere inside Claude Desktop's renderer process, between the user's click and the spawn.

That meant looking at the binary.

I extracted the asar with `npx @electron/asar extract /Applications/Claude.app/Contents/Resources/app.asar /tmp/claude-extracted`. The minified renderer code lives in `.vite/build/index.js` — about 11 MB of JavaScript with everything mangled to single and double-letter names.

I started by grepping for `[1m]`, the suffix that was supposed to get appended. Found it inside one function:

```javascript
function ZAt(t) {
  return /\[1m\]/i.test(t) || !Sn("3885610113") || !/sonnet-4-6|opus-4-6/i.test(t)
    ? t : `${t}[1m]`
}
```

Three conditions joined by OR. If any of them is true, the function returns the model name unchanged. If all three are false, it appends `[1m]`.

Walking through them: the first condition skips anything that already has `[1m]` (idempotency). The second is a server feature-flag check — `Sn("3885610113")` returns whether flag `3885610113` is on for this client, and the leading `!` flips it. The third is a model-name allow-list — only `sonnet-4-6` and `opus-4-6` qualify for the suffix.

The middle condition was the regression. When the flag was on, `!Sn(...)` evaluated to `false` and the function fell through to the suffix. When the flag was off, `!Sn(...)` evaluated to `true` and the suffix was never appended. The flag had been on as of 18:36 on March 19, off as of 19:59. Same binary, different server state.

The function name `ZAt` is minified — it changes between Claude Desktop builds. The flag ID `3885610113` is the only stable string in the area. Any patch had to anchor on the flag ID, not the function name.

The obvious thing to try first was: extract the asar, edit the JavaScript, repack. I'd already extracted, so I just modified the function — replaced the `Sn("...")` call with `false` — and ran `npx @electron/asar pack /tmp/claude-extracted /tmp/app.asar.patched`.

The repacked archive came out at 60 MB. The original was 19 MB. Something was off.

The cause turned out to be benign-looking: the `extract` command pulls files from `app.asar.unpacked` into the extraction directory alongside the actual asar contents — native `.node` binaries that Electron deliberately keeps outside the archive. When `pack` repacked, it pulled those binaries back in. Three times the size.

I copied the inflated asar into place anyway and launched Claude Desktop. Got an `EXC_BREAKPOINT (SIGTRAP)` crash 224 ms after launch, with the top of the stack trace pointing at `node::sea::SeaResource::use_code_cache()`.

That sentence took me a while to understand. V8 caches compiled JavaScript bytecode against the asar's file offsets. When the asar's size or layout changes, every offset shifts; the bytecode cache thinks it's pointing at function `f` and is actually pointing at the middle of a string literal, and V8 hits the trap immediately on first invocation. (See [docs/root-cause-analysis.md](https://github.com/evanjcosgrove/claude-cowork-1m-patch/blob/main/docs/root-cause-analysis.md) for the longer version.)

I had assumed extracting and repacking would work. I was wrong. The extract/repack approach wasn't viable on a freshly-launched binary with a cached bytecode store, regardless of whether the JavaScript inside was correct.

I needed to modify the bytes in place, without changing any offsets.

The constraint was: any byte I changed had to be replaced by exactly the same number of bytes. Then no offsets would shift, and V8's bytecode cache would still point at valid code.

The original expression was 17 bytes:

```
!Sn("3885610113")
```

I needed a same-length JavaScript expression that evaluated to `false`. The shortest is `!1` — three bytes. That left 14 bytes to fill with something the JavaScript parser would ignore.

JavaScript block comments are syntactically valid in expression positions and the comment body can be anything. Block comment delimiters cost four bytes (`/*` and `*/`). Eleven characters of padding fit between them:

```
!1/*___________*/
```

Three bytes for `!1`, four bytes for the comment delimiters, eleven underscores in the middle. Seventeen bytes total. The expression evaluates to `false`. The function falls through to the `[1m]` suffix.

The substitution itself is a raw byte replacement — no JavaScript parsing involved, no AST manipulation, just `read → str_replace → write` against the asar file. The Python that does it asserts the new payload is exactly the same length as the old one before writing, and asserts the unique-occurrence count of the anchor (one match, no more) before replacing. If either invariant fails, the script aborts before touching the binary.

The same trick generalizes: find a stable byte anchor for the flag identifier, swap the surrounding expression for a same-length literal that evaluates to the value you want, leave everything else alone.

After the same-length swap, I copied the patched asar into place and launched. Got an immediate error in the Console:

```
ASAR Integrity Violation: got a hash mismatch
```

The asar header — the JSON that lists every file in the archive with its offset, size, and SHA256 hash — had been left untouched. The JavaScript inside the file had changed by 14 bytes' worth of comment characters, so the per-file SHA256 in the header no longer matched the actual content.

I extracted the header with `@electron/asar`'s `getRawHeader()`, parsed it, and recomputed the SHA256 for `.vite/build/index.js` from the new file content. For files larger than 4 MB, the integrity record stores both a top-level hash and per-block hashes (one per 4 MB chunk). The `.vite/build/index.js` is 11 MB, so three block hashes plus the top-level hash. All four had to be recomputed. Then in-place byte-replacement again — old hex string for new hex string, both 64 characters, no offset shift. Launch.

Different error, same shape:

```
ElectronAsarIntegrity hash mismatch (Resources/app.asar)
```

Layer 3. The asar's header SHA256 is itself stored in `Info.plist` under the `ElectronAsarIntegrity` key, so even if you've updated all the per-file hashes inside the header, the header itself has changed and the plist's record of it is now stale. `plutil -replace ElectronAsarIntegrity.Resources/app\.asar.hash -string "<new hash>" Info.plist` and re-launch.

That layer pattern — try it, fail, read the error, identify the next integrity check, recompute, replace — was the whole work of the next two hours. Modern signed-app integrity isn't a single check; it's a cascade. Electron documents three of the four (file integrity, header integrity, code signature), but the codesign-with-entitlements layer below is implicit. The mechanisms are the same general architecture that the Trail of Bits ASAR integrity bypass exploited a year ago against Signal, 1Password, and Slack ([CVE-2025-55305](https://nvd.nist.gov/vuln/detail/CVE-2025-55305)) and that an earlier bug bypassed at the header level ([CVE-2024-46992](https://nvd.nist.gov/vuln/detail/CVE-2024-46992)). The layers each do their job; you have to peel them in order. (Per-layer reference: [docs/integrity-layers.md](https://github.com/evanjcosgrove/claude-cowork-1m-patch/blob/main/docs/integrity-layers.md).)

Three integrity layers passed; Claude Desktop launched. But Cowork itself wouldn't start. The session-start animation rolled, then a modal: "Invalid installation — Claude's installation appears to be corrupted."

I attached `lldb` to the swift VM helper and traced the message back to a single call:

```
require("@ant/claude-swift").vm.isVirtualizationSupported()
```

which was returning `"entitlement_missing"`. The `com.apple.security.virtualization` entitlement, which Cowork's local VM sandbox needs, was missing from the code signature.

The cause was an earlier `codesign --force --deep --sign -` invocation. The `--deep` flag re-signs every framework inside the app bundle, and that re-signing strips entitlements that aren't in the per-framework Info.plist. Anthropic's own signature on the inner frameworks had carried the virtualization entitlement; mine didn't, because I hadn't passed an entitlements plist.

The fix had to happen in a specific order. Extract Anthropic's entitlements **before** any binary modification, with `codesign -d --entitlements - /Applications/Claude.app > entitlements.plist`. Modify the binary. Re-sign with `codesign --force --sign - --entitlements entitlements.plist /Applications/Claude.app` — without `--deep`, so the inner frameworks keep their original signatures.

It worked.

![Claude Desktop showing claude-opus-4-6[1m] with 547.9k/1m tokens](../img/verification.png)

The screenshot is from a session that had been running unbroken for sixteen days. The same Cowork session ID — the session I'd started before the regression and had been resuming through it — picked up the patched binary on the next spawn and the `[1m]` suffix came back. Token counter showed `547.9k/1m`, the model resolution function was quietly appending the suffix again, and the fan was loud.

I packaged the work into [a single bash script](https://github.com/evanjcosgrove/claude-cowork-1m-patch/blob/main/patch-claude-1m.sh) that does all five steps in sequence — extract entitlements, back up, byte-swap the JavaScript, recompute the per-file and header hashes, re-sign with the preserved entitlements. The same session has continued without interruption since. I'd been quietly using it for about a month before deciding to write any of this up.

Three things from this:

- **Modern signed-app integrity is multi-layered and well-designed.** Bypassing it required understanding all four layers in order: JavaScript application logic, per-file SHA256 hashes inside the asar header, the asar header's own SHA256 hash inside `Info.plist`, and the macOS code signature with its entitlement records. Skipping any one layer broke the next launch. Whoever built this thought through the threat model.
- **V8's bytecode cache is the single most under-discussed constraint in Electron app modification.** Every blog post about asar patching I read while debugging this either omitted the bytecode-cache problem or hand-waved it. The `EXC_BREAKPOINT` 224 ms in is the exact failure mode the same-length-swap technique exists to prevent. Anyone modifying a signed Electron app on a desktop platform will hit this; documenting it more loudly seems worth doing.
- **Server-side feature flags inside client binaries that gate paid functionality create a regression class normal QA misses.** From the QA perspective, the binary works — flag-on, flag-off, both behaviors are intentional. Nothing tests the wrong-default-for-this-customer case. Clients should observe their own flag state and surface it somewhere a user can find it; otherwise paying customers carry the ambiguity and the support burden.

*Postscript (April 18, 2026):* Anthropic shipped `opus-4-7` to Cowork. The patched flag bypass still worked, but a model-allow-list regex one line below — which I had glossed over because it matched the existing models — silently rejected `opus-4-7`. The same byte-anchor approach extended cleanly: a second 19-byte same-length swap (`sonnet-4-6|opus-4-6` → `opus-4-[67](?:)(?:)`). [Full v2 patch in the repo.](https://github.com/evanjcosgrove/claude-cowork-1m-patch)

---

*Code: [github.com/evanjcosgrove/claude-cowork-1m-patch](https://github.com/evanjcosgrove/claude-cowork-1m-patch) · [@evanjcosgrove](https://x.com/evanjcosgrove) · [LinkedIn](https://linkedin.com/in/evanjcosgrove) · [Mastodon](https://cosocial.ca/@evanjcosgrove)*
