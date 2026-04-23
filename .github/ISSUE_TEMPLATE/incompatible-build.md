---
name: Incompatible Claude Desktop build
about: Preflight exits `unknown`, half-patched asar, or a new Claude Desktop version where the script fails.
title: "[unknown build] Claude Desktop vX.X.X - preflight exits unknown"
labels: []
---

<!--
Thanks for reporting. Please fill in every section - the script can't be updated
to support a new build without all of this info.

Read the welcome post first if you haven't:
https://github.com/evanjcosgrove/claude-cowork-1m-patch/discussions/1
-->

## Claude Desktop version

```bash
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  /Applications/Claude.app/Contents/Info.plist
```

Output:

```
<paste version here>
```

## macOS version

```bash
sw_vers -productVersion
```

Output:

```
<paste here>
```

## Setup checklist

Please confirm both before filing this as an incompatible-build issue:

- [ ] I enabled Full Disk Access for the terminal app that ran `./patch-claude-1m.sh` (`Terminal`, `iTerm2`, `Ghostty`, etc.) via `System Settings > Privacy & Security > Full Disk Access`.
- [ ] After patching, I relaunched Claude with `osascript -e 'quit app "Claude"'; sleep 3; open -a Claude`.

## Full script output

Paste the entire `./patch-claude-1m.sh` output below. The lines that matter most are:

- the preflight `State:` line
- `Layer 1a (feature flag): ...`
- `Layer 1b (model allow-list): ...`
- `Virtualization entitlement: ...`

```
<paste full output here>
```

## Cowork log after relaunch

```bash
tail ~/Library/Logs/Claude/cowork_vm_node.log | grep -- '--model'
```

Output:

```
<paste here>
```

## Anything else?

Optional: did the script half-patch? Did Claude relaunch successfully? Any other observations.

---

> [!IMPORTANT]
> **Do not attach the asar itself or any Anthropic binaries.** If the script can't find an anchor, share only the minimal byte context - roughly 20 chars around the missing region. The repo's [scope contract](https://github.com/evanjcosgrove/claude-cowork-1m-patch/blob/main/README.md#scope) is keeping vendor code out of this repo.
