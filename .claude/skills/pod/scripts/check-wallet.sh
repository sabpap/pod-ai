#!/usr/bin/env bash
# Checks that a wallet is available for pod and prints its address. Never prints a key or a password.
#
# Looks for, in this order:
#   1. POD_PRIVATE_KEY: a private key in an environment variable.
#   2. POD_KEYSTORE: the name of a Foundry keystore in POD_KEYSTORE_DIR (default ~/.foundry/keystores).
#      Without POD_KEYSTORE, the folder's only keystore, if it holds exactly one.
# A keystore's address is read from the file when it is stored there in clear. Otherwise the file is
# opened with its password from the macOS Keychain (service "foundry-keystore", account = keystore name).
#
# Prints one JSON object. Success: {"ok": true, "form": ..., "address": ...}.
# Failure: {"ok": false, "error": ...} and exit code 1.

set -euo pipefail

fail() {
  jq -n --arg e "$1" --argjson k "${2:-[]}" '{ok: false, error: $e} + (if $k == [] then {} else {keystores_found: $k} end)'
  exit 1
}

for t in cast jq; do
  command -v "$t" >/dev/null 2>&1 || { echo "{\"ok\": false, \"error\": \"$t is not installed.\"}"; exit 1; }
done

# 1. A private key in the environment. cast sees it as an argument while it runs; it is never printed.
if [ -n "${POD_PRIVATE_KEY:-}" ]; then
  addr=$(cast wallet address --private-key "$POD_PRIVATE_KEY" 2>/dev/null) \
    || fail "POD_PRIVATE_KEY is set but does not hold a valid private key (64 hex characters, with or without 0x)."
  jq -n --arg a "$addr" '{ok: true, form: "private key in environment", variable: "POD_PRIVATE_KEY", address: $a}'
  exit 0
fi

# 2. A Foundry keystore.
dir="${POD_KEYSTORE_DIR:-$HOME/.foundry/keystores}"
found=$(if [ -d "$dir" ]; then ls -1 "$dir"; fi | jq -R . | jq -cs .)
name="${POD_KEYSTORE:-}"
if [ -z "$name" ]; then
  case $(echo "$found" | jq length) in
    0) fail "No wallet found. Set POD_PRIVATE_KEY in your shell, or set POD_KEYSTORE to the name of a Foundry keystore in $dir." ;;
    1) name=$(echo "$found" | jq -r '.[0]') ;;
    *) fail "Several keystores are in $dir. Set POD_KEYSTORE to the one to use." "$found" ;;
  esac
fi
ks="$dir/$name"
[ -f "$ks" ] || fail "There is no keystore called $name in $dir." "$found"
addr=$(jq -r '.address // empty' "$ks" 2>/dev/null) || fail "$ks is not a keystore file."

in_keychain=false
if command -v security >/dev/null 2>&1 && security find-generic-password -s foundry-keystore -a "$name" >/dev/null 2>&1; then
  in_keychain=true
fi

if [ -n "$addr" ]; then
  addr=$(cast to-check-sum-address "0x${addr#0x}")
else
  $in_keychain || fail "The keystore $name does not show its address, and the Keychain holds no password for it (service foundry-keystore, account $name)."
  pw=$(mktemp "${TMPDIR:-/tmp}/pod-pw.XXXXXX")
  trap 'rm -f "$pw"' EXIT
  chmod 600 "$pw"
  # The Keychain adds a trailing newline; cast would read it as part of the password.
  printf '%s' "$(security find-generic-password -s foundry-keystore -a "$name" -w 2>/dev/null)" > "$pw"
  addr=$(cast wallet address --keystore "$ks" --password-file "$pw" 2>/dev/null) \
    || fail "Could not open the keystore $name with the password in the Keychain."
fi

jq -n --arg n "$name" --arg d "$dir" --arg a "$addr" --argjson k "$in_keychain" \
  '{ok: true, form: "foundry keystore", keystore: $n, folder: $d, address: $a, password_in_keychain: $k}'
