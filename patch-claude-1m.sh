#!/bin/bash
set -euo pipefail

# patch-claude-1m.sh - Restore 1M context window in Claude Desktop Cowork
#
# Two same-length JS swaps inside the model-resolution function:
#   Layer 1a - bypass server-side feature flag 3885610113 that gates [1m] suffix
#   Layer 1b - broaden the model allow-list to also cover opus-4-7
#
# Layer 1b has TWO known forms across Claude Desktop versions. The preflight
# detects which form the asar uses and applies the matching same-length swap:
#   Form A (regex; older asars, < v1.3109):
#     /sonnet-4-6|opus-4-6/i.test(e) → /opus-4-[67](?:)(?:)/i.test(e)
#   Form B (array .includes; newer asars, ≥ v1.3109):
#     ["claude-sonnet-4-6","claude-opus-4-6"] → [ "claude-opus-4-6","claude-opus-4-7" ]
#     (substring match against e via .some(t => e.includes(t)) - sonnet
#     intentionally dropped per the "Opus-only scope" caveat in README.)
#
# Idempotent. A Python preflight classifies asar state as
#   needs_1a / needs_1b / needs_both / already_done / unknown
# (using the same byte anchors as the patch blocks) and applies only the
# missing layer(s) in the detected form. Atomic writes (same-dir tempfile +
# fsync + os.replace) and a single EXIT trap that prints a copy-pasteable
# rollback command protect against partial-write corruption. Backups every
# run.
#
# Env overrides:
#   CLAUDE_APP_PATH                        Override /Applications/Claude.app
#                                          (e.g. for testing on a copy).
#   ALLOW_PATCH_WITHOUT_ENTITLEMENTS=1     Skip the entitlements hard-fail.
#                                          Cowork will likely show
#                                          "Invalid installation" until you
#                                          re-extract entitlements.
#   PATCH_RESTORE_ON_FAIL=1                On any non-zero exit AFTER backup,
#                                          automatically restore from the
#                                          just-made backup. Default: print
#                                          the rollback command and let you
#                                          decide.

APP_BUNDLE="${CLAUDE_APP_PATH:-/Applications/Claude.app}"
ASAR_PATH="$APP_BUNDLE/Contents/Resources/app.asar"
PLIST_PATH="$APP_BUNDLE/Contents/Info.plist"
BACKUP_DIR="$HOME/Desktop"

# Pinned to keep installs reproducible across re-runs and machines. A silent
# transitive change in @electron/asar's header parser would silently corrupt
# the patch, so bump intentionally and re-test.
ASAR_PINNED_VERSION="4.2.0"

ENT_PATH=""          # set by mktemp after pre-checks
NPM_PREFIX_DIR=""    # set by mktemp -d only if we install asar
BACKUP_PATH=""       # set after Step 2
PLIST_BACKUP_PATH="" # set after Step 2

# --- Single EXIT trap: rollback messaging + temp cleanup ---
# Fires on ANY exit (explicit `exit N`, set -e failure, or INT/TERM signal).
# We disarm inside the handler so it can't re-fire.
on_exit() {
  local exit_code=$?
  trap - EXIT INT TERM

  # Always clean up the entitlements tmp file.
  if [ -n "$ENT_PATH" ] && [ -f "$ENT_PATH" ]; then
    rm -f "$ENT_PATH"
  fi
  if [ -n "$NPM_PREFIX_DIR" ] && [ -d "$NPM_PREFIX_DIR" ]; then
    rm -rf "$NPM_PREFIX_DIR"
  fi

  # If we failed AFTER making a backup, surface the rollback command.
  if [ "$exit_code" -ne 0 ] \
    && [ -n "$BACKUP_PATH" ] && [ -f "$BACKUP_PATH" ] \
    && [ -n "$PLIST_BACKUP_PATH" ] && [ -f "$PLIST_BACKUP_PATH" ]; then
    echo ""
    echo "=== Patch FAILED (exit $exit_code) ==="
    if [ "${PATCH_RESTORE_ON_FAIL:-0}" = "1" ]; then
      echo "PATCH_RESTORE_ON_FAIL=1 - auto-restoring from backup..."
      if cp "$BACKUP_PATH" "$ASAR_PATH" 2>/dev/null \
        && cp "$PLIST_BACKUP_PATH" "$PLIST_PATH" 2>/dev/null; then
        echo "Restored. Re-launch Claude with: open -a Claude"
      else
        echo "Auto-restore FAILED. Restore manually:"
        echo "  cp '$BACKUP_PATH' '$ASAR_PATH'"
        echo "  cp '$PLIST_BACKUP_PATH' '$PLIST_PATH'"
      fi
    else
      echo "To restore from the backup just made:"
      echo "  cp '$BACKUP_PATH' '$ASAR_PATH'"
      echo "  cp '$PLIST_BACKUP_PATH' '$PLIST_PATH'"
      echo "  open -a Claude"
      echo ""
      echo "(Set PATCH_RESTORE_ON_FAIL=1 to auto-restore on the next failure.)"
    fi
  fi

  exit "$exit_code"
}
trap on_exit EXIT INT TERM

echo "=== Claude Desktop 1M Context Patch ==="
echo ""
echo "App bundle: $APP_BUNDLE"
echo ""

# --- Pre-checks ---
if [ ! -f "$ASAR_PATH" ]; then
  echo "ERROR: Claude Desktop not found at $APP_BUNDLE"
  echo "       (override with CLAUDE_APP_PATH=/path/to/Claude.app)"
  exit 1
fi

if ! command -v node &>/dev/null; then
  echo "ERROR: Node.js is required. Install from nodejs.org"
  exit 1
fi

if ! command -v python3 &>/dev/null; then
  echo "ERROR: Python 3 is required"
  exit 1
fi

if ! command -v codesign &>/dev/null; then
  echo "ERROR: codesign is required (install Xcode Command Line Tools)"
  exit 1
fi

if ! command -v plutil &>/dev/null; then
  echo "ERROR: plutil is required (macOS only)"
  exit 1
fi

# Atomic writes need to create a tempfile in the asar's directory; codesign
# rewrites the asar in place. Both require write access.
ASAR_DIR="$(dirname "$ASAR_PATH")"
if [ ! -w "$ASAR_DIR" ]; then
  echo "ERROR: $ASAR_DIR is not writable. Fix permissions or run with sudo."
  exit 1
fi
if [ ! -w "$PLIST_PATH" ]; then
  echo "ERROR: $PLIST_PATH is not writable. Fix permissions or run with sudo."
  exit 1
fi

# Find or install @electron/asar (pinned). We still check the global and
# local node_modules first to skip a download when possible; a bare-tmp
# install only happens when neither is present.
ASAR_MODULE=""
for candidate in \
  "$(npm root -g 2>/dev/null)/@electron/asar/lib/asar.js" \
  "./node_modules/@electron/asar/lib/asar.js"; do
  if [ -f "$candidate" ]; then
    ASAR_MODULE="$candidate"
    break
  fi
done

if [ -z "$ASAR_MODULE" ]; then
  if ! command -v npm &>/dev/null; then
    echo "ERROR: npm is required to install @electron/asar."
    echo "       Install Node.js (which ships with npm) or pre-install:"
    echo "         npm install -g @electron/asar@$ASAR_PINNED_VERSION"
    exit 1
  fi
  NPM_PREFIX_DIR="$(mktemp -d -t claude-patch)"
  echo "Installing @electron/asar@$ASAR_PINNED_VERSION to $NPM_PREFIX_DIR..."
  # --ignore-scripts: @electron/asar is pure JS and runs no install scripts.
  # Setting this defends against a future supply-chain attack landing a
  # postinstall hook in a transitive dep.
  npm install --prefix "$NPM_PREFIX_DIR" --ignore-scripts \
    "@electron/asar@$ASAR_PINNED_VERSION"
  ASAR_MODULE="$NPM_PREFIX_DIR/node_modules/@electron/asar/lib/asar.js"
  if [ ! -f "$ASAR_MODULE" ]; then
    echo "ERROR: Failed to install @electron/asar. Check Node.js/npm."
    exit 1
  fi
fi

echo "Using asar module: $ASAR_MODULE"

# --- Preflight: classify asar state ---
echo ""
echo "Classifying asar patch state..."
if ! PREFLIGHT_OUTPUT=$(python3 - "$ASAR_PATH" << 'PYEOF'
import re, sys

asar_path = sys.argv[1]
flag_id = b'3885610113'

with open(asar_path, 'rb') as f:
    data = f.read()

# Layer 1a - same patterns as the Layer 1a patch block below.
# Both quote variants because minified output can use either.
flag_patterns = [
    rb'!\w+\("' + flag_id + rb'"\)',
    rb"!\w+\('" + flag_id + rb"'\)",
]
flag_matches = []
for p in flag_patterns:
    flag_matches.extend(re.findall(p, data))

# Layer 1b - TWO known forms. Same anchors as the Layer 1b patch blocks below.
# Form A (regex): older asars (< v1.3109).
# Form B (array): newer asars (≥ v1.3109) that swapped the regex literal for
#                 a JS array used with .some(t => e.includes(t)).
regex_anchor = b'sonnet-4-6|opus-4-6'
array_anchor = b'["claude-sonnet-4-6","claude-opus-4-6"]'
regex_count = data.count(regex_anchor)
array_count = data.count(array_anchor)

# Positive "patched" markers. The 1a marker uses a regex (not exact length)
# so a future minifier change that produces a longer/shorter variable name
# still classifies correctly. The 1b markers are exact byte sequences chosen
# to be unique post-patch.
patched_1a = bool(re.search(rb'!1/\*_+\*/', data))
patched_1b_regex = data.count(b'opus-4-[67](?:)(?:)') >= 1
patched_1b_array = data.count(b'[ "claude-opus-4-6","claude-opus-4-7" ]') >= 1
patched_1b = patched_1b_regex or patched_1b_array

# Decide which Layer 1b form this asar uses, unambiguously. A given asar
# should have exactly one form (either still unpatched or already patched).
# Anything else (both forms, neither form, multiple matches) is ambiguous
# and routes to 'unknown'.
form_1b = 'none'
needs_1b = False
if regex_count == 1 and array_count == 0 and not patched_1b_array:
    form_1b = 'regex'
    needs_1b = True
elif array_count == 1 and regex_count == 0 and not patched_1b_regex:
    form_1b = 'array'
    needs_1b = True
elif regex_count == 0 and array_count == 0 and patched_1b_regex and not patched_1b_array:
    form_1b = 'regex'
elif regex_count == 0 and array_count == 0 and patched_1b_array and not patched_1b_regex:
    form_1b = 'array'

needs_1a = len(flag_matches) == 1

if form_1b == 'none':
    # Form unrecognized - neither anchor present in either state. Anthropic
    # likely refactored the gate again. Refuse rather than half-patch.
    state = 'unknown'
elif needs_1a and needs_1b:
    state = 'needs_both'
elif needs_1a:
    state = 'needs_1a'
elif needs_1b:
    state = 'needs_1b'
elif patched_1a and patched_1b and len(flag_matches) == 0 \
        and regex_count == 0 and array_count == 0:
    state = 'already_done'
else:
    state = 'unknown'

print(f"STATE={state}")
print(f"NEEDS_1A={'1' if needs_1a else '0'}")
print(f"NEEDS_1B={'1' if needs_1b else '0'}")
print(f"FORM_1B={form_1b}")
print(f"FLAG_MATCHES={len(flag_matches)}")
print(f"REGEX_COUNT={regex_count}")
print(f"ARRAY_COUNT={array_count}")
print(f"PATCHED_1A={'1' if patched_1a else '0'}")
print(f"PATCHED_1B_REGEX={'1' if patched_1b_regex else '0'}")
print(f"PATCHED_1B_ARRAY={'1' if patched_1b_array else '0'}")
PYEOF
); then
  echo "ERROR: preflight Python failed (asar unreadable or pattern crash)"
  exit 1
fi

# Defense-in-depth: only eval if every line is a clean KEY=value pair, so a
# stray Python print or traceback can't smuggle shell into the eval below.
while IFS= read -r preflight_line; do
  if ! [[ "$preflight_line" =~ ^[A-Z0-9_]+=[a-zA-Z0-9_]+$ ]]; then
    echo "ERROR: preflight output malformed: $preflight_line"
    exit 1
  fi
done <<< "$PREFLIGHT_OUTPUT"
eval "$PREFLIGHT_OUTPUT"

layer_status() {
  # $1 = NEEDS, $2 = PATCHED
  if [ "$1" = "1" ]; then echo NEEDED
  elif [ "$2" = "1" ]; then echo done
  else echo absent
  fi
}

if [ "$PATCHED_1B_REGEX" = "1" ] || [ "$PATCHED_1B_ARRAY" = "1" ]; then
  PATCHED_1B=1
else
  PATCHED_1B=0
fi

echo "  State:    $STATE"
echo "  Layer 1a: $(layer_status "$NEEDS_1A" "$PATCHED_1A")"
echo "  Layer 1b: $(layer_status "$NEEDS_1B" "$PATCHED_1B") (form: $FORM_1B)"

case "$STATE" in
  already_done)
    echo ""
    echo "Already fully patched. Both layers' patched markers are present."
    echo "To re-patch after a Claude Desktop update, run this script again."
    exit 0
    ;;
  unknown)
    echo ""
    echo "ERROR: Unable to classify asar state."
    echo "       Neither the unpatched anchors nor the patched markers match"
    echo "       cleanly. This Claude Desktop build doesn't fit the expected"
    echo "       pattern."
    echo ""
    echo "       Diagnostics:"
    echo "         flag matches:   $FLAG_MATCHES"
    echo "         regex anchors:  $REGEX_COUNT"
    echo "         patched 1a:     $PATCHED_1A"
    echo "         patched 1b:     $PATCHED_1B"
    echo ""
    echo "       Open an issue with your Claude Desktop version (Help > About)."
    exit 1
    ;;
  needs_1a|needs_1b|needs_both)
    : # fall through to patch
    ;;
esac

# --- Step 1: Extract entitlements (BEFORE backup, BEFORE any mutation) ---
echo ""
ENT_PATH="$(mktemp -t claude-entitlements)"
echo "[1/7] Extracting entitlements -> $ENT_PATH..."
codesign -d --entitlements :"$ENT_PATH" "$APP_BUNDLE" 2>/dev/null || true

if [ ! -s "$ENT_PATH" ]; then
  if [ "${ALLOW_PATCH_WITHOUT_ENTITLEMENTS:-0}" = "1" ]; then
    echo "WARNING: Entitlements empty, but ALLOW_PATCH_WITHOUT_ENTITLEMENTS=1 set."
    echo "         Cowork will likely show 'Invalid installation' after patching."
  else
    echo "ERROR: Could not extract entitlements (file is missing or empty)."
    echo "       Without the original entitlements, re-signing strips"
    echo "       com.apple.security.virtualization and Cowork breaks."
    echo ""
    echo "       Try manually to confirm extraction works:"
    echo "         codesign -d --entitlements :/tmp/check.plist $APP_BUNDLE"
    echo "         cat /tmp/check.plist"
    echo ""
    echo "       To proceed anyway (Cowork will likely break):"
    echo "         ALLOW_PATCH_WITHOUT_ENTITLEMENTS=1 ./patch-claude-1m.sh"
    exit 1
  fi
fi

# --- Step 2: Backup ---
BACKUP_TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_PATH="$BACKUP_DIR/app.asar.backup-$BACKUP_TS"
PLIST_BACKUP_PATH="$BACKUP_DIR/Info.plist.backup-$BACKUP_TS"
echo "[2/7] Creating backups..."
cp "$ASAR_PATH" "$BACKUP_PATH"
cp "$PLIST_PATH" "$PLIST_BACKUP_PATH"
echo "  app.asar:   $BACKUP_PATH"
echo "  Info.plist: $PLIST_BACKUP_PATH"
# From this point on, the EXIT trap will print rollback instructions
# (or auto-restore if PATCH_RESTORE_ON_FAIL=1) on any failure.

# --- Step 3: Patch Layer 1a (feature flag bypass) ---
if [ "$NEEDS_1A" = "1" ]; then
  echo "[3/7] Patching Layer 1a (feature flag bypass)..."
  python3 - "$ASAR_PATH" << 'PYEOF'
import os, re, sys, tempfile

asar_path = sys.argv[1]
flag_id = b'3885610113'

with open(asar_path, 'rb') as f:
    data = f.read()

original_size = len(data)

patterns = [
    rb'!\w+\("' + flag_id + rb'"\)',
    rb"!\w+\('" + flag_id + rb"'\)",
]
all_matches = []
for p in patterns:
    all_matches.extend(re.findall(p, data))

# Mirror Layer 1b's exact-one-match guard: more than one is ambiguous.
if len(all_matches) != 1:
    print(f"ERROR: Expected exactly 1 flag-bypass pattern, found {len(all_matches)}")
    sys.exit(1)

old_js = all_matches[0]
pad_len = len(old_js) - 6  # "!1/*" + "*/" = 6 fixed bytes
new_js = b'!1/*' + b'_' * pad_len + b'*/'

assert len(old_js) == len(new_js), f"Length mismatch: {len(old_js)} vs {len(new_js)}"

new_data = data.replace(old_js, new_js, 1)
assert len(new_data) == original_size

# Atomic write: same-dir tempfile + fsync + os.replace.
asar_dir = os.path.dirname(asar_path)
fd, tmp_path = tempfile.mkstemp(dir=asar_dir, prefix='.app.asar.tmp.')
try:
    with os.fdopen(fd, 'wb') as f:
        f.write(new_data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp_path, asar_path)
except Exception:
    if os.path.exists(tmp_path):
        os.unlink(tmp_path)
    raise

print(f"  Replaced: {old_js.decode()} -> {new_js.decode()}")
PYEOF
else
  echo "[3/7] Layer 1a already applied - skipping."
fi

# --- Step 4: Patch Layer 1b (model allow-list broaden to include opus-4-7) ---
if [ "$NEEDS_1B" = "1" ]; then
  echo "[4/7] Patching Layer 1b ($FORM_1B form)..."
  python3 - "$ASAR_PATH" "$FORM_1B" << 'PYEOF'
import os, sys, tempfile

asar_path = sys.argv[1]
form = sys.argv[2]

# Both forms broaden the allow-list to cover opus-4-6 AND opus-4-7,
# intentionally dropping sonnet-4-6 (see README "Opus-only scope" caveat).
if form == 'regex':
    old = b'sonnet-4-6|opus-4-6'   # 19 bytes - older asars (< v1.3109)
    new = b'opus-4-[67](?:)(?:)'   # 19 bytes - same-length swap
elif form == 'array':
    old = b'["claude-sonnet-4-6","claude-opus-4-6"]'   # 39 bytes - newer asars (≥ v1.3109)
    new = b'[ "claude-opus-4-6","claude-opus-4-7" ]'   # 39 bytes - same-length swap
else:
    print(f"ERROR: unknown Layer 1b form: {form}")
    sys.exit(1)

assert len(old) == len(new), f"Length mismatch: {len(old)} vs {len(new)}"

with open(asar_path, 'rb') as f:
    data = f.read()

original_size = len(data)
count = data.count(old)
if count != 1:
    print(f"ERROR: Expected 1 occurrence of {form} anchor, found {count}")
    sys.exit(1)

new_data = data.replace(old, new, 1)
assert len(new_data) == original_size

asar_dir = os.path.dirname(asar_path)
fd, tmp_path = tempfile.mkstemp(dir=asar_dir, prefix='.app.asar.tmp.')
try:
    with os.fdopen(fd, 'wb') as f:
        f.write(new_data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp_path, asar_path)
except Exception:
    if os.path.exists(tmp_path):
        os.unlink(tmp_path)
    raise

print(f"  Replaced: /{old.decode()}/i -> /{new.decode()}/i")
PYEOF
else
  echo "[4/7] Layer 1b already applied - skipping."
fi

# --- Step 5: Update per-file integrity hashes ---
echo "[5/7] Updating integrity hashes..."
# Pass paths via env to Node so a path containing spaces or shell metacharacters
# (e.g., a `npm root -g` install under a home dir with spaces) can't break the
# inline -e script.
HASH_OUTPUT=$(ASAR_MODULE="$ASAR_MODULE" ASAR_PATH_ENV="$ASAR_PATH" node -e '
const asar = require(process.env.ASAR_MODULE);
const crypto = require("crypto");
const asarPath = process.env.ASAR_PATH_ENV;
const content = asar.extractFile(asarPath, ".vite/build/index.js");
const newHash = crypto.createHash("sha256").update(content).digest("hex");
const blockSize = 4194304;
const blocks = [];
for (let i = 0; i < content.length; i += blockSize) {
  blocks.push(crypto.createHash("sha256").update(content.subarray(i, Math.min(i + blockSize, content.length))).digest("hex"));
}
const header = JSON.parse(asar.getRawHeader(asarPath).headerString);
const entry = header.files[".vite"].files["build"].files["index.js"];
const oldHash = entry.integrity.hash;
const changedBlocks = [];
entry.integrity.blocks.forEach((b, i) => {
  if (b !== blocks[i]) changedBlocks.push({idx: i, old: b, new: blocks[i]});
});
console.log(JSON.stringify({oldHash, newHash, changedBlocks}));
')

# Pass JSON via argv (literal heredoc, no bash expansion in the Python body)
# so any odd characters in the hash payload can't break parsing.
python3 - "$ASAR_PATH" "$HASH_OUTPUT" << 'PYEOF'
import json, os, sys, tempfile

asar_path = sys.argv[1]
hash_data = json.loads(sys.argv[2])

with open(asar_path, 'rb') as f:
    data = f.read()

original_size = len(data)

old_fh = hash_data['oldHash'].encode()
new_fh = hash_data['newHash'].encode()
assert data.count(old_fh) == 1, "File hash not found uniquely"
data = data.replace(old_fh, new_fh, 1)

for block in hash_data['changedBlocks']:
    old_bh = block['old'].encode()
    new_bh = block['new'].encode()
    assert data.count(old_bh) == 1, "Block hash not found uniquely"
    data = data.replace(old_bh, new_bh, 1)

assert len(data) == original_size

asar_dir = os.path.dirname(asar_path)
fd, tmp_path = tempfile.mkstemp(dir=asar_dir, prefix='.app.asar.tmp.')
try:
    with os.fdopen(fd, 'wb') as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp_path, asar_path)
except Exception:
    if os.path.exists(tmp_path):
        os.unlink(tmp_path)
    raise

print(f"  File hash: {hash_data['oldHash'][:16]}... -> {hash_data['newHash'][:16]}...")
print(f"  Changed blocks: {len(hash_data['changedBlocks'])}")
PYEOF

# --- Step 6: Update Info.plist header hash ---
echo "[6/7] Updating Info.plist..."
NEW_HEADER_HASH=$(ASAR_MODULE="$ASAR_MODULE" ASAR_PATH_ENV="$ASAR_PATH" node -e '
const asar = require(process.env.ASAR_MODULE);
const crypto = require("crypto");
const h = asar.getRawHeader(process.env.ASAR_PATH_ENV);
console.log(crypto.createHash("sha256").update(h.headerString).digest("hex"));
')

plutil -replace ElectronAsarIntegrity.Resources/app\\.asar.hash \
  -string "$NEW_HEADER_HASH" "$PLIST_PATH"
echo "  Header hash: $NEW_HEADER_HASH"

# --- Step 7: Re-sign with entitlements ---
echo "[7/7] Re-signing with entitlements..."
xattr -cr "$APP_BUNDLE" 2>/dev/null || true

if [ -s "$ENT_PATH" ]; then
  codesign --force --sign - --entitlements "$ENT_PATH" "$APP_BUNDLE"
  echo "  Signed with original entitlements (virtualization preserved)"
else
  codesign --force --sign - "$APP_BUNDLE"
  echo "  WARNING: Signed without entitlements (ALLOW_PATCH_WITHOUT_ENTITLEMENTS=1)."
  echo "           Cowork VM will likely show 'Invalid installation'."
fi

# --- Verify (re-run the same preflight; expect 'already_done') ---
echo ""
echo "=== Verification ==="
if ! VERIFY_OUTPUT=$(python3 - "$ASAR_PATH" << 'PYEOF'
import re, sys

asar_path = sys.argv[1]
flag_id = b'3885610113'

with open(asar_path, 'rb') as f:
    data = f.read()

flag_patterns = [
    rb'!\w+\("' + flag_id + rb'"\)',
    rb"!\w+\('" + flag_id + rb"'\)",
]
flag_matches = []
for p in flag_patterns:
    flag_matches.extend(re.findall(p, data))

regex_count = data.count(b'sonnet-4-6|opus-4-6')
array_count = data.count(b'["claude-sonnet-4-6","claude-opus-4-6"]')
patched_1a = bool(re.search(rb'!1/\*_+\*/', data))
patched_1b_regex = data.count(b'opus-4-[67](?:)(?:)') >= 1
patched_1b_array = data.count(b'[ "claude-opus-4-6","claude-opus-4-7" ]') >= 1
patched_1b = patched_1b_regex or patched_1b_array

ok = (not flag_matches) and regex_count == 0 and array_count == 0 \
        and patched_1a and patched_1b
print(f"OK={'1' if ok else '0'}")
print(f"FLAG_MATCHES={len(flag_matches)}")
print(f"REGEX_COUNT={regex_count}")
print(f"ARRAY_COUNT={array_count}")
print(f"PATCHED_1A={'1' if patched_1a else '0'}")
print(f"PATCHED_1B_REGEX={'1' if patched_1b_regex else '0'}")
print(f"PATCHED_1B_ARRAY={'1' if patched_1b_array else '0'}")
PYEOF
); then
  echo "ERROR: verification Python failed"
  exit 1
fi

while IFS= read -r verify_line; do
  if ! [[ "$verify_line" =~ ^[A-Z0-9_]+=[a-zA-Z0-9_]+$ ]]; then
    echo "ERROR: verify output malformed: $verify_line"
    exit 1
  fi
done <<< "$VERIFY_OUTPUT"
eval "$VERIFY_OUTPUT"

if [ "$OK" != "1" ]; then
  echo "  FAILED: post-patch state does not match 'already_done'."
  echo "    unpatched flag matches:    $FLAG_MATCHES"
  echo "    unpatched regex count:     $REGEX_COUNT"
  echo "    unpatched array count:     $ARRAY_COUNT"
  echo "    patched 1a marker:         $PATCHED_1A"
  echo "    patched 1b regex marker:   $PATCHED_1B_REGEX"
  echo "    patched 1b array marker:   $PATCHED_1B_ARRAY"
  exit 1
fi

echo "  Layer 1a (feature flag):     BYPASSED"
echo "  Layer 1b (model allow-list): BROADENED (matches opus-4-6 and opus-4-7)"

VIRT_ENT=$(codesign -d --entitlements :- "$APP_BUNDLE" 2>/dev/null | grep -c "virtualization" || true)
if [ "$VIRT_ENT" -gt 0 ]; then
  echo "  Virtualization entitlement:  PRESENT"
else
  echo "  Virtualization entitlement:  MISSING (Cowork may not work)"
fi

echo ""
echo "=== Patch complete ==="
echo "Backup: $BACKUP_PATH"
echo ""
echo "Next steps:"
echo "  1. Quit Claude Desktop: osascript -e 'quit app \"Claude\"'"
echo "  2. Relaunch: open -a Claude"
echo "  3. Start a NEW Cowork session (existing sessions keep old model)"
echo "  4. Verify: model should show 'Opus 4.6 Extended', 'Opus 4.7 Extended', or similar"
echo "     (or grep ~/Library/Logs/Claude/cowork_vm_node.log for 'opus-4-7[1m]')"
echo ""
echo "Rollback: cp '$BACKUP_PATH' '$ASAR_PATH' && cp '$PLIST_BACKUP_PATH' '$PLIST_PATH' && open -a Claude"
