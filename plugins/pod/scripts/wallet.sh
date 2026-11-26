#!/usr/bin/env bash
# The wallet contract every section uses. It hides whether the key is a Foundry keystore (password in
# the macOS Keychain) or a private key in an environment variable.
#
# Usage:
#   wallet.sh [--keystore NAME | --env VAR] address
#   wallet.sh [--keystore NAME | --env VAR] type
#   wallet.sh [--keystore NAME | --env VAR] sign-message MESSAGE
#   wallet.sh [--keystore NAME | --env VAR] send TO SIGNATURE [ARGS...] [--nonce N]
#
# Without --keystore or --env, the wallet comes from the saved profile.
# `send` encodes the call, signs it with Foundry's cast, and sends it with eth_sendRawTransaction.
# It refuses any network other than pod staging.
#
# Secrets: the keystore password goes to cast through a private temp file, deleted on exit. A private
# key from an environment variable is passed to cast as an argument, so it is visible to this user's
# own processes while cast runs (cast has no environment option for raw keys). Neither is ever printed.

source "$(dirname "$0")/lib.sh"

wtype="" ; wref=""
case "${1:-}" in
  --keystore) wtype="keystore"; wref="${2:-}"; shift 2 || true ;;
  --env)      wtype="env";      wref="${2:-}"; shift 2 || true ;;
esac
if [ -z "$wtype" ]; then
  profile_exists || fail wallet "No wallet is connected." "Run /pod:setup first."
  wtype=$(profile_get '.wallet.type')
  if [ "$wtype" = "keystore" ]; then wref=$(profile_get '.wallet.keystore'); else wref=$(profile_get '.wallet.env_var'); fi
fi
[ -n "$wref" ] || fail wallet "No wallet name was given."

cmd="${1:-}"; shift || true

PWFILE=""; ERRFILE=""
cleanup() { rm -f ${PWFILE:+"$PWFILE"} ${ERRFILE:+"$ERRFILE"}; return 0; }
trap cleanup EXIT
trap 'exit 130' INT TERM

# Sets SIGNER (an array of cast arguments) for the chosen wallet.
# The trap is set again here because this can run inside $(...), and a subshell does not inherit
# the parent's EXIT trap: without it the password file would be left behind.
load_signer() {
  if [ "$wtype" = "keystore" ]; then
    local ks="$KEYSTORE_DIR/$wref"
    [ -f "$ks" ] || fail wallet "There is no keystore called $wref in $KEYSTORE_DIR." "Run list-wallets.sh to see the keystores."
    command -v security >/dev/null 2>&1 || fail wallet "The macOS Keychain tool (security) is not available." "Use an environment-variable wallet on this machine."
    trap cleanup EXIT
    trap 'exit 130' INT TERM
    PWFILE=$(mktemp "${TMPDIR:-/tmp}/pod-plugin.XXXXXX")
    chmod 600 "$PWFILE"
    if ! security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$wref" -w > "$PWFILE" 2>/dev/null; then
      fail wallet "The keystore $wref has no password in the Keychain." \
        "Run: security add-generic-password -s $KEYCHAIN_SERVICE -a $wref -w"
    fi
    # The Keychain adds a trailing newline; cast would read it as part of the password.
    printf '%s' "$(cat "$PWFILE")" > "$PWFILE"
    SIGNER=(--keystore "$ks" --password-file "$PWFILE")
  else
    local key="${!wref:-}"
    [ -n "$key" ] || fail wallet "The variable $wref is not set in this session." "Export it in the shell that starts Claude Code."
    SIGNER=(--private-key "$key")
  fi
}

address() {
  if [ "$wtype" = "keystore" ]; then
    local ks="$KEYSTORE_DIR/$wref" a
    [ -f "$ks" ] || fail wallet "There is no keystore called $wref in $KEYSTORE_DIR." "Run list-wallets.sh to see the keystores."
    a=$(jq -r '.address // empty' "$ks")   # some keystores store it in clear
    if [ -n "$a" ]; then cast to-check-sum-address "0x${a#0x}"; return; fi
    load_signer                            # otherwise it takes the password to decrypt
    cast wallet address "${SIGNER[@]}" 2>/dev/null || fail wallet "Could not open the keystore $wref with its Keychain password." "Check the password stored in the Keychain."
  else
    load_signer
    cast wallet address "${SIGNER[@]}" 2>/dev/null || fail wallet "The variable $wref does not hold a valid private key." "It must be 64 hex characters, with or without 0x."
  fi
}

case "$cmd" in
  type)
    jq -n --arg t "$wtype" --arg r "$wref" \
      '{ok: true, type: $t} + (if $t == "keystore" then {keystore: $r} else {env_var: $r} end)'
    ;;

  address)
    a=$(address) || { echo "$a"; exit 1; }
    jq -n --arg a "$a" --arg t "$wtype" '{ok: true, address: $a, type: $t}'
    ;;

  sign-message)
    msg="${1:-}"; [ -n "$msg" ] || fail wallet "sign-message needs a message."
    load_signer
    sig=$(cast wallet sign "${SIGNER[@]}" "$msg" 2>/dev/null) || fail wallet "The wallet could not sign." "Check the keystore password or the private key."
    jq -n --arg m "$msg" --arg s "$sig" '{ok: true, message: $m, signature: $s}'
    ;;

  send)
    to="${1:-}"; sig="${2:-}"; shift 2 || fail send "send needs a contract address and a function signature."
    nonce_args=() ; call_args=()
    while [ $# -gt 0 ]; do
      if [ "$1" = "--nonce" ]; then nonce_args=(--nonce "$2"); shift 2; else call_args+=("$1"); shift; fi
    done
    require_staging
    load_signer
    ERRFILE=$(mktemp "${TMPDIR:-/tmp}/pod-plugin-err.XXXXXX")
    raw=$(cast mktx "$to" "$sig" ${call_args[@]+"${call_args[@]}"} --rpc-url "$POD_RPC" --chain "$STAGING_CHAIN_ID" \
          ${nonce_args[@]+"${nonce_args[@]}"} "${SIGNER[@]}" 2>"$ERRFILE") \
      || fail send "Could not build or sign the transaction: $(tail -1 "$ERRFILE")"
    case "$raw" in 0x*) ;; *) fail send "cast did not return a signed transaction." ;; esac
    out=$(rpc eth_sendRawTransaction "[\"$raw\"]") || fail send "Pod did not answer the send." "Try again; check the nonce first."
    if [ "$(echo "$out" | jq 'has("error")')" = "true" ]; then
      code=$(echo "$out" | jq -r '.error.code')
      msg=$(echo "$out" | jq -r '.error.message')
      case "$code" in
        -32025) fail send "Pod refused the transaction: not available in your region ($code)." ;;
        *) case "$msg" in
             *lacklist*) fail send "Pod refused the transaction: the account or transaction is blacklisted ($code)." ;;
             *) fail send "Pod refused the transaction: $msg ($code)." ;;
           esac ;;
      esac
    fi
    jq -n --arg tx "$(echo "$out" | jq -r '.result')" '{ok: true, tx: $tx}'
    ;;

  *)
    fail wallet "Unknown command '$cmd'." "Use address, type, sign-message or send."
    ;;
esac
