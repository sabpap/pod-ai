#!/usr/bin/env bash
# Setup step 3: which Foundry keystores exist, and does each have its password in the Keychain?
# Run as: pod setup wallets
# Never reads a password: the Keychain lookup checks that an entry exists without asking for its
# secret. Foundry keystores usually do not store the address in clear, so "address" is often null;
# pod setup works it out once a keystore is chosen.

source "$(dirname "$0")/lib.sh"

rows="[]"
if [ -d "$KEYSTORE_DIR" ]; then
  for f in "$KEYSTORE_DIR"/*; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    jq -e '.crypto' "$f" >/dev/null 2>&1 || continue   # not a keystore file
    addr=$(jq -r '.address // empty' "$f" 2>/dev/null || true)
    has_pw=false
    if command -v security >/dev/null 2>&1 && \
       security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$name" >/dev/null 2>&1; then
      has_pw=true
    fi
    rows=$(echo "$rows" | jq --arg n "$name" --arg a "$addr" --argjson p "$has_pw" \
      '. + [{name: $n, address: (if $a == "" then null else "0x" + ($a | ltrimstr("0x")) end), keychain_password: $p}]')
  done
fi

jq -n --arg dir "$KEYSTORE_DIR" --argjson rows "$rows" \
  '{ok: true, keystore_dir: $dir, keystores: $rows,
    env_wallet: "Or connect a private key held in an environment variable (default POD_PRIVATE_KEY)."}'
