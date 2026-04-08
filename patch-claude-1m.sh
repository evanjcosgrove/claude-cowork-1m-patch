#!/bin/bash
set -euo pipefail

# patch-claude-1m.sh — Restore 1M context window in Claude Desktop Cowork
# Bypasses server-side feature flag 3885610113 that gates [1m] model suffix
# Safe to run multiple times (idempotent). Creates backups every run.

ASAR_PATH="/Applications/Claude.app/Contents/Resources/app.asar"
PLIST_PATH="/Applications/Claude.app/Contents/Info.plist"
BACKUP_DIR="$HOME/Desktop"
FLAG_ID="3885610113"
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
  "/private/tmp/claude/node_modules/@electron/asar/lib/asar.js" \
  "./node_modules/@electron/asar/lib/asar.js"; do
  if [ -f "$candidate" ]; then
    ASAR_MODULE="$candidate"
    break
  fi
done

if [ -z "$ASAR_MODULE" ]; then
  echo "Installing @electron/asar..."
  npm install --prefix /tmp/claude-patch @electron/asar 2>/dev/null
  ASAR_MODULE="/tmp/claude-patch/node_modules/@electron/asar/lib/asar.js"
fi

echo "Using asar module: $ASAR_MODULE"

# --- Check if already patched ---
if ! grep -q "$FLAG_ID" "$ASAR_PATH" 2>/dev/null; then
  echo ""
  echo "Already patched (flag ID $FLAG_ID not found in asar)."
  echo "To re-patch after an update, reinstall Claude Desktop first."
  exit 0
fi

# --- Step 1: Extract entitlements ---
echo "[1/6] Extracting entitlements..."
codesign -d --entitlements :"$ENT_PATH" /Applications/Claude.app 2>/dev/null
if [ ! -f "$ENT_PATH" ] || [ ! -s "$ENT_PATH" ]; then
  echo "WARNING: Could not extract entitlements. Cowork VM may not work."
fi

# --- Step 2: Backup ---
BACKUP_PATH="$BACKUP_DIR/app.asar.backup-$(date +%Y%m%d-%H%M%S)"
echo "[2/6] Creating backup at $BACKUP_PATH..."
cp "$ASAR_PATH" "$BACKUP_PATH"

# --- Step 3: Patch JS (binary in-place) ---
echo "[3/6] Patching feature flag..."
python3 << 'PYEOF'
import re, sys

asar_path = '/Applications/Claude.app/Contents/Resources/app.asar'
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
pad_len = len(old_js) - 5  # 5 = len("!1/**/")
new_js = b'!1/*' + b'_' * pad_len + b'*/'

assert len(old_js) == len(new_js), f"Length mismatch: {len(old_js)} vs {len(new_js)}"

data = data.replace(old_js, new_js, 1)
assert len(data) == original_size

with open(asar_path, 'wb') as f:
    f.write(data)

print(f"  Replaced: {old_js.decode()} -> {new_js.decode()}")
PYEOF

# --- Step 4: Update per-file integrity hashes ---
echo "[4/6] Updating integrity hashes..."
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

# --- Step 5: Update Info.plist header hash ---
echo "[5/6] Updating Info.plist..."
NEW_HEADER_HASH=$(node -e "
const asar = require('$ASAR_MODULE');
const crypto = require('crypto');
const h = asar.getRawHeader('$ASAR_PATH');
console.log(crypto.createHash('sha256').update(h.headerString).digest('hex'));
")

plutil -replace ElectronAsarIntegrity.Resources/app\\.asar.hash \
  -string "$NEW_HEADER_HASH" "$PLIST_PATH"
echo "  Header hash: $NEW_HEADER_HASH"

# --- Step 6: Re-sign with entitlements ---
echo "[6/6] Re-signing with entitlements..."
xattr -cr /Applications/Claude.app 2>/dev/null || true

if [ -f "$ENT_PATH" ] && [ -s "$ENT_PATH" ]; then
  codesign --force --sign - --entitlements "$ENT_PATH" /Applications/Claude.app 2>/dev/null
  echo "  Signed with original entitlements (virtualization preserved)"
else
  codesign --force --sign - /Applications/Claude.app 2>/dev/null
  echo "  WARNING: Signed without entitlements. Cowork VM may show 'Invalid installation'."
fi

# --- Verify ---
echo ""
echo "=== Verification ==="
if grep -q "$FLAG_ID" "$ASAR_PATH" 2>/dev/null; then
  echo "FAILED: Flag ID still present in asar!"
  exit 1
fi
echo "  Feature flag: BYPASSED"

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
echo "  4. Verify: model should show 'Opus 4.6 Extended' or similar"
echo ""
echo "Rollback: cp '$BACKUP_PATH' '$ASAR_PATH' && open -a Claude"
