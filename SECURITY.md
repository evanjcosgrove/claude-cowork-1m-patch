# Security Policy

This repository distributes a script that patches a local install of Claude Desktop on macOS. Any vulnerability that affects the patch process, the resulting bundle's signature, or could lead a user to execute unintended code is in scope.

## Reporting a vulnerability

**Please do not open a public GitHub issue for security reports.**

Use GitHub's private vulnerability reporting flow:

**→ [Report a vulnerability](https://github.com/evanjcosgrove/claude-cowork-1m-patch/security/advisories/new)**

This routes your report through GitHub's private Security Advisories - no public issue, no email. I'm the only recipient, and the advisory stays private until a fix is ready.

Expect an acknowledgement within 7 days. Public disclosure will be coordinated with whatever fix lands in the script; credit is given unless you request anonymity.

## In scope

- Bugs in `patch-claude-1m.sh` that cause unintended file mutation, privilege escalation, or an integrity-layer bypass beyond what the script documents.
- Regressions in the same-length swap logic that could corrupt `app.asar`.
- Issues in the `@electron/asar` install path (e.g. a way to land arbitrary code despite `--ignore-scripts`).
- Any way the script could be tricked into running outside the user's local `/Applications/Claude.app` (or `CLAUDE_APP_PATH`) target.

## Out of scope

- Anthropic's product behavior, including the underlying server-flag rollback this patch addresses.
- Anything that requires an attacker to already have write access to your `/Applications` directory, your shell environment, or your code-signing chain.
- The fact that this tool modifies a signed third-party app - that is the documented behavior, see [README § Scope](README.md#scope).
- Anything that would only matter if the repo distributed patched binaries (it does not - see [README § Legal](README.md#legal)).
