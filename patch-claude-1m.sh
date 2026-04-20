#!/bin/bash
set -euo pipefail

# patch-claude-1m.sh — Restore 1M context window in Claude Desktop Cowork
#
# Two same-length JS swaps inside the model-resolution function (`ZAt`):
#   Layer 1a — bypass server-side feature flag 3885610113 that gates [1m] suffix
#   Layer 1b — broaden the model allow-list regex /sonnet-4-6|opus-4-6/i so it
#              also matches opus-4-7 (Anthropic shipped 4-7 to Cowork without
#              re-enabling 1M for it). New regex: /opus-4-[67](?:)(?:)/i.
#
# Safe to run multiple times (idempotent): each layer is detected by its own
# byte anchor in the asar and applied only when missing. Backups every run.

ASAR_PATH="/Applications/Claude.app/Contents/Resources/app.asar"
PLIST_PATH="/Applications/Claude.app/Contents/Info.plist"
BACKUP_DIR="$HOME/Desktop"
FLAG_ID="3885610113"
REGEX_ANCHOR="sonnet-4-6|opus-4-6"
ENT_PATH="/tmp/claude-entitlements.plist"

echo "=== Claude Desktop 1M Context Patch ==="
echo ""

# --- Pre-checks ---
if [ ! -f "$ASAR_PATH" ]; then
  echo "ERROR: Claude Desktop not found at /Applications/Claude.app"
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

# Check if @electron/asar is available
ASAR_MODULE=""
for candidate in \
  "$(npm root -g 2>/dev/null)/@electron/asar/lib/asar.js" \
  "/tmp/claude-patch/node_modules/@electron/asar/lib/asar.js" \
  "./node_modules/@electron/asar/lib/asar.js"; do
  if [ -f "$candidate" ]; then
    ASAR_MODULE="$candidate"
    break
  fi
done

if [ -z "$ASAR_MODULE" ]; then
  echo "Installing @electron/asar to /tmp/claude-patch..."
  npm install --prefix /tmp/claude-patch @electron/asar
  ASAR_MODULE="/tmp/claude-patch/node_modules/@electron/asar/lib/asar.js"
  if [ ! -f "$ASAR_MODULE" ]; then
    echo "ERROR: Failed to install @electron/asar. Check your Node.js/npm installation."
    exit 1
  fi
fi

echo "Using asar module: $ASAR_MODULE"

# --- Determine patch state from byte anchors ---
# Each layer's "unpatched" anchor is searched independently, so re-running the
# script after a partial patch only applies the missing layer(s).
HAS_FLAG=0
HAS_REGEX=0
grep -q "$FLAG_ID" "$ASAR_PATH" 2>/dev/null && HAS_FLAG=1
grep -q -F "$REGEX_ANCHOR" "$ASAR_PATH" 2>/dev/null && HAS_REGEX=1

if [ "$HAS_FLAG" -eq 0 ] && [ "$HAS_REGEX" -eq 0 ]; then
  echo ""
  echo "Already fully patched (both anchors absent from asar)."
  echo "To re-patch after a Claude Desktop update, run this script again."
  exit 0
fi

echo ""
echo "Patch state:"
echo "  Layer 1a (flag bypass):       $([ $HAS_FLAG  -eq 1 ] && echo NEEDED || echo done)"
echo "  Layer 1b (model allow-list):  $([ $HAS_REGEX -eq 1 ] && echo NEEDED || echo done)"

# --- Step 1: Extract entitlements ---
echo "[1/7] Extracting entitlements..."
codesign -d --entitlements :"$ENT_PATH" /Applications/Claude.app 2>/dev/null
if [ ! -f "$ENT_PATH" ] || [ ! -s "$ENT_PATH" ]; then
  echo "WARNING: Could not extract entitlements."
  echo "  Cowork will likely show 'Invalid installation' after patching."
  echo "  Try: codesign -d --entitlements :/tmp/claude-entitlements.plist /Applications/Claude.app"
fi

# --- Step 2: Backup ---
BACKUP_TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_PATH="$BACKUP_DIR/app.asar.backup-$BACKUP_TS"
PLIST_BACKUP_PATH="$BACKUP_DIR/Info.plist.backup-$BACKUP_TS"
echo "[2/7] Creating backups..."
cp "$ASAR_PATH" "$BACKUP_PATH"
cp "$PLIST_PATH" "$PLIST_BACKUP_PATH"
echo "  app.asar:  $BACKUP_PATH"
echo "  Info.plist: $PLIST_BACKUP_PATH"

# --- Step 3: Patch Layer 1a (feature flag bypass) ---
if [ "$HAS_FLAG" -eq 1 ]; then
  echo "[3/7] Patching Layer 1a (feature flag bypass)..."
  python3 << PYEOF
import re, sys

asar_path = '$ASAR_PATH'
flag_id = b'3885610113'

with open(asar_path, 'rb') as f:
    data = f.read()

original_size = len(data)

# Find the feature flag pattern: !SomeFunc("3885610113")
pattern = rb'!\w+\("' + flag_id + rb'"\)'
match = re.search(pattern, data)
if not match:
    # Try single quotes
    pattern = rb"!\w+\('" + flag_id + rb"'\)"
    match = re.search(pattern, data)

if not match:
    print(f"ERROR: Could not find feature flag {flag_id.decode()} in asar")
    sys.exit(1)

old_js = match.group(0)
# Build same-length replacement: !1/*____..._*/
pad_len = len(old_js) - 6  # len("!1/*") + len("*/") = 6 fixed bytes
new_js = b'!1/*' + b'_' * pad_len + b'*/'

assert len(old_js) == len(new_js), f"Length mismatch: {len(old_js)} vs {len(new_js)}"

data = data.replace(old_js, new_js, 1)
assert len(data) == original_size

with open(asar_path, 'wb') as f:
    f.write(data)

print(f"  Replaced: {old_js.decode()} -> {new_js.decode()}")
PYEOF
else
  echo "[3/7] Layer 1a already applied — skipping."
fi

# --- Step 4: Patch Layer 1b (model allow-list broaden to include opus-4-7) ---
if [ "$HAS_REGEX" -eq 1 ]; then
  echo "[4/7] Patching Layer 1b (model allow-list)..."
  python3 << PYEOF
import sys

asar_path = '$ASAR_PATH'
old = b'sonnet-4-6|opus-4-6'   # 19 bytes — matches sonnet-4-6, opus-4-6
new = b'opus-4-[67](?:)(?:)'   # 19 bytes — matches ONLY opus-4-6, opus-4-7

assert len(old) == len(new), f"Length mismatch: {len(old)} vs {len(new)}"

with open(asar_path, 'rb') as f:
    data = f.read()

original_size = len(data)
count = data.count(old)
if count != 1:
    print(f"ERROR: Expected 1 occurrence of model regex anchor, found {count}")
    sys.exit(1)

data = data.replace(old, new, 1)
assert len(data) == original_size

with open(asar_path, 'wb') as f:
    f.write(data)

print(f"  Replaced: /{old.decode()}/i -> /{new.decode()}/i")
PYEOF
else
  echo "[4/7] Layer 1b already applied — skipping."
fi

# --- Step 5: Update per-file integrity hashes ---
echo "[5/7] Updating integrity hashes..."
HASH_OUTPUT=$(node -e "
const asar = require('$ASAR_MODULE');
const crypto = require('crypto');
const asarPath = '$ASAR_PATH';
const content = asar.extractFile(asarPath, '.vite/build/index.js');
const newHash = crypto.createHash('sha256').update(content).digest('hex');
const blockSize = 4194304;
const blocks = [];
for (let i = 0; i < content.length; i += blockSize) {
  blocks.push(crypto.createHash('sha256').update(content.subarray(i, Math.min(i + blockSize, content.length))).digest('hex'));
}
const header = JSON.parse(asar.getRawHeader(asarPath).headerString);
const entry = header.files['.vite'].files['build'].files['index.js'];
const oldHash = entry.integrity.hash;
const changedBlocks = [];
entry.integrity.blocks.forEach((b, i) => {
  if (b !== blocks[i]) changedBlocks.push({idx: i, old: b, new: blocks[i]});
});
console.log(JSON.stringify({oldHash, newHash, changedBlocks}));
")

python3 << PYEOF
import json, sys

asar_path = '$ASAR_PATH'
hash_data = json.loads('''$HASH_OUTPUT''')

with open(asar_path, 'rb') as f:
    data = f.read()

original_size = len(data)

# Replace file hash
old_fh = hash_data['oldHash'].encode()
new_fh = hash_data['newHash'].encode()
assert data.count(old_fh) == 1, f"File hash not found uniquely"
data = data.replace(old_fh, new_fh, 1)

# Replace changed block hashes
for block in hash_data['changedBlocks']:
    old_bh = block['old'].encode()
    new_bh = block['new'].encode()
    assert data.count(old_bh) == 1, f"Block hash not found uniquely"
    data = data.replace(old_bh, new_bh, 1)

assert len(data) == original_size
with open(asar_path, 'wb') as f:
    f.write(data)

print(f"  File hash: {hash_data['oldHash'][:16]}... -> {hash_data['newHash'][:16]}...")
print(f"  Changed blocks: {len(hash_data['changedBlocks'])}")
PYEOF

# --- Step 6: Update Info.plist header hash ---
echo "[6/7] Updating Info.plist..."
NEW_HEADER_HASH=$(node -e "
const asar = require('$ASAR_MODULE');
const crypto = require('crypto');
const h = asar.getRawHeader('$ASAR_PATH');
console.log(crypto.createHash('sha256').update(h.headerString).digest('hex'));
")

plutil -replace ElectronAsarIntegrity.Resources/app\\.asar.hash \
  -string "$NEW_HEADER_HASH" "$PLIST_PATH"
echo "  Header hash: $NEW_HEADER_HASH"

# --- Step 7: Re-sign with entitlements ---
echo "[7/7] Re-signing with entitlements..."
xattr -cr /Applications/Claude.app 2>/dev/null || true

if [ -f "$ENT_PATH" ] && [ -s "$ENT_PATH" ]; then
  codesign --force --sign - --entitlements "$ENT_PATH" /Applications/Claude.app
  echo "  Signed with original entitlements (virtualization preserved)"
else
  codesign --force --sign - /Applications/Claude.app
  echo "  WARNING: Signed without entitlements. Cowork VM may show 'Invalid installation'."
fi

# --- Verify ---
echo ""
echo "=== Verification ==="
if grep -q "$FLAG_ID" "$ASAR_PATH" 2>/dev/null; then
  echo "FAILED: Flag ID still present in asar!"
  exit 1
fi
echo "  Layer 1a (feature flag):     BYPASSED"

if grep -q -F "$REGEX_ANCHOR" "$ASAR_PATH" 2>/dev/null; then
  echo "FAILED: Original model regex still present in asar!"
  exit 1
fi
echo "  Layer 1b (model allow-list): BROADENED (matches opus-4-6 and opus-4-7)"

VIRT_ENT=$(codesign -d --entitlements :- /Applications/Claude.app 2>/dev/null | grep -c "virtualization" || true)
if [ "$VIRT_ENT" -gt 0 ]; then
  echo "  Virtualization entitlement: PRESENT"
else
  echo "  Virtualization entitlement: MISSING (Cowork may not work)"
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
