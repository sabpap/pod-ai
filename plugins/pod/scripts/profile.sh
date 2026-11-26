#!/usr/bin/env bash
# Read, save and delete the connected-wallet profile (~/.config/pod-plugin/profile.json).
# The profile never holds a private key or a password.
#
# Usage:
#   profile.sh show                         the profile, or {"ok": true, "connected": false}
#   profile.sh path                         where it lives
#   profile.sh save --keystore NAME --address ADDR
#   profile.sh save --env VAR --address ADDR
#   profile.sh set-test < result.json       store a test-transaction result
#   profile.sh delete                       disconnect (the wallet itself is not touched)

source "$(dirname "$0")/lib.sh"

cmd="${1:-show}"; shift || true

case "$cmd" in
  path)
    jq -n --arg p "$PROFILE" '{ok: true, path: $p}'
    ;;

  show)
    if profile_exists; then
      jq '{ok: true, connected: true, path: input_filename} + .' "$PROFILE"
    else
      jq -n --arg p "$PROFILE" '{ok: true, connected: false, path: $p}'
    fi
    ;;

  save)
    wtype=""; wref=""; addr=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --keystore) wtype=keystore; wref="$2"; shift 2 ;;
        --env) wtype=env; wref="$2"; shift 2 ;;
        --address) addr="$2"; shift 2 ;;
        *) fail profile "Unknown option $1." ;;
      esac
    done
    [ -n "$wtype" ] && [ -n "$wref" ] && [ -n "$addr" ] || fail profile "save needs a wallet (--keystore or --env) and --address."
    jq -n --arg name "$STAGING_NAME" --argjson chain "$STAGING_CHAIN_ID" \
      --arg rest "$STAGING_REST" --arg rpc "$STAGING_RPC" --arg ws "$STAGING_WS" \
      --arg t "$wtype" --arg r "$wref" --arg a "$addr" --arg at "$(now_iso)" '
      {version: 1,
       network: {name: $name, chain_id: $chain, rest: $rest, rpc: $rpc, ws: $ws},
       wallet: {type: $t,
                keystore: (if $t == "keystore" then $r else null end),
                env_var: (if $t == "env" then $r else null end),
                address: $a},
       connected_at: $at,
       test_transaction: null}' | profile_write
    jq '{ok: true, saved: true} + .' "$PROFILE"
    ;;

  set-test)
    profile_exists || fail profile "No profile to update." "Run /pod:setup first."
    result=$(cat)
    echo "$result" | jq -e . >/dev/null || fail profile "The test result is not valid JSON."
    jq --argjson r "$result" '.test_transaction = $r' "$PROFILE" | profile_write
    jq '{ok: true} + {test_transaction: .test_transaction}' "$PROFILE"
    ;;

  delete)
    if profile_exists; then
      rm -f "$PROFILE"
      jq -n '{ok: true, disconnected: true, note: "The profile was deleted. The keystore, the Keychain and any environment variable were not touched."}'
    else
      jq -n '{ok: true, disconnected: true, note: "No wallet was connected."}'
    fi
    ;;

  *)
    fail profile "Unknown command '$cmd'." "Use show, path, save, set-test or delete."
    ;;
esac
