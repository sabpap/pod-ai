#!/usr/bin/env bash
# Sign and send ONE transaction to pod staging, then report what pod said. It does not build orders,
# round, size or follow outcomes: you encode the call from the manual, this script signs and sends it.
#
# Usage:
#   pod-send.sh --check                          is a wallet available, and does pod staging answer?
#   pod-send.sh [options] SIGNATURE [ARGS...]    e.g. 'cancel(bytes32,bytes32,uint128)' BOOK ORDER_ID DEADLINE
#   pod-send.sh [options] --data 0xCALLDATA      a call you encoded yourself (cast calldata ...)
#
# ARGS go to Foundry's cast as they are: integers as plain decimal (already 10^18-scaled where the
# manual says so; negative sizes as -123), bytes32 ids and addresses as 0x hex, bool as true/false,
# bytes[] as [0xaa..,0xbb..].
#
# Options:
#   --dry-run          sign, check and show the transaction, but do not send it
#   --keystore NAME    a Foundry keystore (name in ~/.foundry/keystores, or a path)
#   --key-env VAR      a private key held in the environment variable VAR
#   --nonce N          use this nonce (default: eth_getTransactionCount ADDRESS "pending")
#   --to ADDRESS       contract to call (default: pod's order book 0x50d0000000000000000000000000000000000002)
#   --wait SECONDS     how long to wait for pod_getTxStatus to say "finalized" (default 10)
#
# The wallet, when no option names one: POD_PRIVATE_KEY (a private key) or POD_KEYSTORE (a keystore
# name or path). Setting both is refused. A keystore's password comes from the file named in
# POD_KEYSTORE_PASSWORD_FILE, else from the macOS Keychain (service foundry-keystore, account = the
# keystore name), the same entry `cast wallet` and the pod plugin use. POD_KEYSTORE_DIR changes the
# keystore folder.
#
# Output: one JSON object. {"ok": true, ...} on success; {"ok": false, "step", "error", "fix"} and
# exit 1 otherwise. Only pod staging (chain id 129302) is accepted; POD_RPC_URL may point elsewhere
# for tests, and the chain id is checked before anything is signed. The key and the password are never
# printed. A private key from the environment is passed to cast as an argument (cast has no other
# way), so this user's own processes can see it while cast runs; a keystore has no such exposure.

set -euo pipefail

STAGING_CHAIN_ID=129302
RPC="${POD_RPC_URL:-https://staging-rpc.podtestnet.dev}"
ORDERBOOK=0x50d0000000000000000000000000000000000002
KEYSTORE_DIR="${POD_KEYSTORE_DIR:-$HOME/.foundry/keystores}"
KEYCHAIN_SERVICE=foundry-keystore

usage() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; }

SECRET=""   # the private key, when it comes from the environment: scrubbed from any error text
scrub() { local s="$1"; if [ -n "$SECRET" ]; then s="${s//$SECRET/[redacted]}"; s="${s//${SECRET#0x}/[redacted]}"; fi; printf '%s' "$s"; }

# fail STEP ERROR [FIX] [EXTRA_JSON]: print the failure object and exit 1.
fail() {
  local extra="${4:-}"; [ -n "$extra" ] || extra='{}'
  jq -n --arg step "$1" --arg error "$(scrub "$2")" --arg fix "$(scrub "${3:-}")" --argjson extra "$extra" \
    '{ok: false, step: $step, error: $error} + (if $fix == "" then {} else {fix: $fix} end) + $extra'
  exit 1
}

command -v cast >/dev/null 2>&1 || fail tools "Foundry's cast is not installed." "Install Foundry: brew install foundry (or https://getfoundry.sh)."
command -v jq >/dev/null 2>&1 || { echo '{"ok":false,"step":"tools","error":"jq is not installed.","fix":"brew install jq"}'; exit 1; }
command -v curl >/dev/null 2>&1 || fail tools "curl is not installed."

# --- arguments ---------------------------------------------------------------------------------------

check=false; dry=false; keystore=""; key_env=""; nonce=""; to="$ORDERBOOK"; data=""; wait_s=10; pos=()
while [ $# -gt 0 ]; do
  case "$1" in
    --check) check=true; shift ;;
    --dry-run) dry=true; shift ;;
    --keystore) keystore="${2:-}"; shift 2 || fail args "--keystore needs a name." ;;
    --key-env) key_env="${2:-}"; shift 2 || fail args "--key-env needs a variable name." ;;
    --nonce) nonce="${2:-}"; shift 2 || fail args "--nonce needs a number." ;;
    --to) to="${2:-}"; shift 2 || fail args "--to needs an address." ;;
    --data) data="${2:-}"; shift 2 || fail args "--data needs 0x calldata." ;;
    --wait) wait_s="${2:-}"; shift 2 || fail args "--wait needs a number of seconds." ;;
    -h|--help) usage; exit 0 ;;
    --*) fail args "Unknown option $1." "See: pod-send.sh --help" ;;
    *) pos+=("$1"); shift ;;
  esac
done
[ -z "$nonce" ] || [[ "$nonce" =~ ^[0-9]+$ ]] || fail args "--nonce must be a whole number."
[[ "$wait_s" =~ ^[0-9]+$ ]] || fail args "--wait must be a whole number of seconds."
[[ "$to" =~ ^0x[0-9a-fA-F]{40}$ ]] || fail args "--to must be an address (0x and 40 hex characters)."
if ! $check; then
  if [ -n "$data" ]; then
    [ "${#pos[@]}" -eq 0 ] || fail args "Give either --data or a SIGNATURE with ARGS, not both."
    [[ "$data" =~ ^0x([0-9a-fA-F]{2}){4,}$ ]] || fail args "--data must be 0x calldata: a 4-byte selector and its arguments, in hex."
  else
    [ "${#pos[@]}" -gt 0 ] || fail args "Name the call: a function SIGNATURE and its ARGS, or --data 0xCALLDATA." "See: pod-send.sh --help"
    [[ "${pos[0]}" =~ ^[A-Za-z_][A-Za-z0-9_]*\(.*\)$ ]] || fail args "'${pos[0]}' is not a function signature such as 'cancel(bytes32,bytes32,uint128)'."
  fi
fi

# --- the wallet ---------------------------------------------------------------------------------------

TMP=$(mktemp -d "${TMPDIR:-/tmp}/pod-send.XXXXXX")
chmod 700 "$TMP"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

keystore_names() {   # the keystore names found, as a JSON array (names only; nothing is opened)
  local f names='[]'
  if [ -d "$KEYSTORE_DIR" ]; then
    for f in "$KEYSTORE_DIR"/*; do
      [ -f "$f" ] && jq -e '.crypto' "$f" >/dev/null 2>&1 || continue
      names=$(echo "$names" | jq --arg n "$(basename "$f")" '. + [$n]')
    done
  fi
  echo "$names"
}

wtype=""; wref=""
if [ -n "$keystore" ] && [ -n "$key_env" ]; then fail wallet "Give either --keystore or --key-env, not both."
elif [ -n "$keystore" ]; then wtype=keystore; wref="$keystore"
elif [ -n "$key_env" ]; then wtype=env; wref="$key_env"
elif [ -n "${POD_PRIVATE_KEY:-}" ] && [ -n "${POD_KEYSTORE:-}" ]; then
  fail wallet "Both POD_PRIVATE_KEY and POD_KEYSTORE are set, so the wallet is ambiguous." "Unset one of them, or name the wallet with --keystore or --key-env."
elif [ -n "${POD_PRIVATE_KEY:-}" ]; then wtype=env; wref=POD_PRIVATE_KEY
elif [ -n "${POD_KEYSTORE:-}" ]; then wtype=keystore; wref="$POD_KEYSTORE"
else
  fail wallet "No wallet is available: neither POD_PRIVATE_KEY nor POD_KEYSTORE is set, and no --keystore or --key-env was given." \
    "Ask the user which wallet to use. Never ask them to paste a private key into the chat. A keystore found below can be named with --keystore NAME once its password is in the Keychain (security add-generic-password -s foundry-keystore -a NAME -w, typed by the user), or the user can export POD_PRIVATE_KEY in the shell that starts the agent." \
    "$(jq -n --arg d "$KEYSTORE_DIR" --argjson k "$(keystore_names)" '{keystore_dir: $d, keystores_found: $k}')"
fi

SIGNER=(); PWSOURCE=""
if [ "$wtype" = keystore ]; then
  case "$wref" in */*) KS="$wref" ;; *) KS="$KEYSTORE_DIR/$wref" ;; esac
  [ -f "$KS" ] || fail wallet "There is no keystore $wref (looked for $KS)." "pod-send.sh --check lists the keystores found." \
    "$(jq -n --argjson k "$(keystore_names)" '{keystores_found: $k}')"
  jq -e '.crypto' "$KS" >/dev/null 2>&1 || fail wallet "$KS is not a keystore file."
  PWFILE="$TMP/pw"
  if [ -n "${POD_KEYSTORE_PASSWORD_FILE:-}" ]; then
    [ -r "$POD_KEYSTORE_PASSWORD_FILE" ] || fail wallet "The password file named in POD_KEYSTORE_PASSWORD_FILE cannot be read."
    (umask 077; printf '%s' "$(cat "$POD_KEYSTORE_PASSWORD_FILE")" > "$PWFILE")
    PWSOURCE=file
  else
    command -v security >/dev/null 2>&1 || fail wallet "No password source: POD_KEYSTORE_PASSWORD_FILE is not set and the macOS Keychain is not available." \
      "Set POD_KEYSTORE_PASSWORD_FILE to a file only you can read, or use POD_PRIVATE_KEY."
    name=$(basename "$KS")
    (umask 077; security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$name" -w > "$PWFILE" 2>/dev/null) \
      || fail wallet "The keystore $name has no password in the macOS Keychain." \
           "The user stores it once, typing the password themselves: security add-generic-password -s $KEYCHAIN_SERVICE -a $name -w"
    # The Keychain adds a trailing newline; cast would read it as part of the password.
    (umask 077; printf '%s' "$(cat "$PWFILE")" > "$PWFILE.1"); mv "$PWFILE.1" "$PWFILE"
    PWSOURCE=keychain
  fi
  SIGNER=(--keystore "$KS" --password-file "$PWFILE")
  addr=$(cast wallet address "${SIGNER[@]}" 2>/dev/null) || fail wallet "Could not open the keystore $wref with its password." "Check the password stored for it."
  wallet_json=$(jq -n --arg a "$addr" --arg k "$KS" --arg p "$PWSOURCE" '{type: "keystore", keystore: $k, password_from: $p, address: $a}')
else
  [[ "$wref" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail wallet "'$wref' is not an environment variable name."
  SECRET="${!wref:-}"
  [ -n "$SECRET" ] || fail wallet "The variable $wref is not set in this session." "The user exports it in the shell that starts the agent. Never paste a key into the chat."
  [[ "$SECRET" =~ ^(0x)?[0-9a-fA-F]{64}$ ]] || { SECRET=""; fail wallet "The variable $wref does not hold a private key (64 hex characters, with or without 0x)."; }
  SIGNER=(--private-key "$SECRET")
  addr=$(cast wallet address "${SIGNER[@]}" 2>/dev/null) || fail wallet "The variable $wref does not hold a valid private key."
  wallet_json=$(jq -n --arg a "$addr" --arg v "$wref" '{type: "env", env_var: $v, address: $a}')
fi

# --- the network --------------------------------------------------------------------------------------

rpc() {   # rpc METHOD PARAMS_JSON: the whole JSON-RPC answer, or non-zero when pod does not answer
  curl -sS --fail --max-time 15 -X POST "$RPC" -H 'content-type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" 2>/dev/null
}

chain_hex=$(rpc eth_chainId '[]' | jq -r '.result // empty' 2>/dev/null) || chain_hex=""
[ -n "$chain_hex" ] || fail network "The network at $RPC did not answer eth_chainId. Nothing was signed or sent." "Try again in a moment."
chain_id=$(cast to-dec "$chain_hex" 2>/dev/null || echo "?")
[ "$chain_id" = "$STAGING_CHAIN_ID" ] || fail network \
  "The network at $RPC answered with chain id $chain_id, not pod staging ($STAGING_CHAIN_ID). Nothing was signed or sent." \
  "This script only sends on pod staging."

if $check; then
  writes=$(rpc pod_status '[]' | jq -c '.result // null' 2>/dev/null || echo null)
  next_nonce=$(rpc eth_getTransactionCount "[\"$addr\",\"pending\"]" | jq -r '.result // empty' 2>/dev/null || true)
  [ -n "$next_nonce" ] && next_nonce=$(cast to-dec "$next_nonce" 2>/dev/null || true)
  jq -n --argjson w "$wallet_json" --arg rpc "$RPC" --argjson st "$writes" --arg n "$next_nonce" '
    {ok: true, wallet: $w,
     network: {rpc: $rpc, chain_id: 129302, name: "pod staging",
               writes_open: (if $st == null then null else (($st.read_only // false) or ($st.paused // false)) | not end)},
     next_nonce: (if $n == "" then null else ($n | tonumber) end),
     note: "The wallet opens and pod staging answers. Whether the account has cash is on GET /v1/clob/balances/ADDRESS."}'
  exit 0
fi

# --- build and sign -----------------------------------------------------------------------------------

if [ -z "$nonce" ]; then
  nonce_hex=$(rpc eth_getTransactionCount "[\"$addr\",\"pending\"]" | jq -r '.result // empty' 2>/dev/null) || nonce_hex=""
  [ -n "$nonce_hex" ] || fail nonce "Pod did not answer eth_getTransactionCount for $addr. Nothing was signed or sent." "Try again in a moment."
  nonce=$(cast to-dec "$nonce_hex")
fi

if [ -n "$data" ]; then
  calldata=$(echo "$data" | tr 'A-F' 'a-f'); fn="(raw calldata)"; args_json='[]'
else
  fn="${pos[0]}"
  args_json='[]'
  [ "${#pos[@]}" -gt 1 ] && args_json=$(jq -nc '$ARGS.positional' --args -- "${pos[@]:1}")
  calldata=$(cast calldata "${pos[@]}" 2>"$TMP/err") \
    || fail encode "cast could not encode $fn with these arguments: $(tail -1 "$TMP/err")" "Check the number and types of the arguments against the signature."
fi
selector="${calldata:0:10}"

raw=$(cast mktx --rpc-url "$RPC" --chain "$STAGING_CHAIN_ID" --nonce "$nonce" "${SIGNER[@]}" "$to" "$calldata" 2>"$TMP/err") \
  || fail sign "Could not build or sign the transaction: $(tail -1 "$TMP/err")" "" "$(jq -n --arg f "$addr" --argjson n "$nonce" '{from: $f, nonce: $n}')"
case "$raw" in 0x02*) ;; *) fail sign "cast did not return a signed EIP-1559 transaction." ;; esac

decoded=$(cast decode-tx "$raw" 2>/dev/null) || fail sign "The signed transaction does not decode."
tx_hash=$(cast keccak "$raw")
# Check that what was signed is exactly what was asked, before anything leaves this machine.
signed_nonce=$(cast to-dec "$(echo "$decoded" | jq -r '.nonce')" 2>/dev/null || echo "?")
echo "$decoded" | jq -e --arg c "0x$(printf '%x' "$STAGING_CHAIN_ID")" --arg to "$to" --arg in "$calldata" --arg from "$addr" '
  (.chainId | ascii_downcase) == $c and (.to | ascii_downcase) == ($to | ascii_downcase)
  and (.input | ascii_downcase) == $in and (.signer | ascii_downcase) == ($from | ascii_downcase)
  and (.value == "0x0")' >/dev/null && [ "$signed_nonce" = "$nonce" ] \
  || fail sign "The signed transaction does not match the request (chain, contract, calldata, signer or nonce). Nothing was sent."

order_id=""
case "$selector" in
  "$(cast sig 'submitOrder(bytes32,int256,uint256,uint8,uint128,uint128,uint8)')"|"$(cast sig 'submitTrigger(bytes32,int256,uint256,uint256,uint8,uint8,uint128,uint128,bool,bool)')")
    order_id=$(cast keccak "$(cast abi-encode 'f(address,uint64,uint32)' "$addr" "$nonce" 0)") ;;
esac

summary=$(jq -n --arg from "$addr" --arg to "$to" --argjson n "$nonce" --arg fn "$fn" --argjson args "$args_json" \
  --arg cd "$calldata" --arg tx "$tx_hash" --arg oid "$order_id" '
  {from: $from, to: $to, chain_id: 129302, nonce: $n, function: $fn, args: $args, calldata: $cd, tx: $tx}
  + (if $oid == "" then {} else {order_id: $oid} end)')

if $dry; then
  jq -n --argjson s "$summary" --arg raw "$raw" --argjson d "$decoded" '
    {ok: true, dry_run: true, sent: false} + $s
    + {raw_tx: $raw, decoded: ($d | {type, chainId, nonce, gas, maxFeePerGas, maxPriorityFeePerGas, to, value, input, signer, hash}),
       note: "Signed and checked, not sent. Run the same command without --dry-run to send it; the nonce is read again then unless --nonce is given."}'
  exit 0
fi

# --- send ---------------------------------------------------------------------------------------------

resp=$(rpc eth_sendRawTransaction "[\"$raw\"]") || fail send \
  "Pod did not answer the send, so it may or may not have arrived." \
  "Check pod_getTxStatus for $tx_hash before sending again; sending twice with a new nonce could place the order twice." "$summary"

if [ "$(echo "$resp" | jq 'has("error")')" = true ]; then
  code=$(echo "$resp" | jq -r '.error.code')
  msg=$(echo "$resp" | jq -r '.error.message // ""')
  edata=$(echo "$resp" | jq -r '.error.data // "" | if type == "string" then . else tojson end')
  reason="$edata"
  if [ "$code" = 3 ] && [[ "$edata" =~ ^0x08c379a0 ]]; then
    reason=$(cast abi-decode 'f()(string)' "0x${edata:10}" 2>/dev/null | sed 's/^"//; s/"$//' || echo "$edata")
  fi
  case "$code" in
    996)    fix="A nonce clash or a pending transaction. Check pod_getTxStatus of any earlier attempt, then send again without --nonce so a fresh pending nonce is read." ;;
    -32025) fix="Pod refuses transactions from this region. This wallet cannot trade from here." ;;
    3)      fix="The order book refused the call. Fix what the reason names (deadline grid, price step, size step, flags) and send a corrected call." ;;
    -32000) fix="Pod's validation refused it for the reason given (for example Insufficient balance, Invalid chain ID, Transaction is blacklisted)." ;;
    -32003) fix="A quorum of validators rejected it, for the reasons given." ;;
    *)      fix="See the error codes in the manual's basics." ;;
  esac
  fail send "Pod refused the transaction: $msg${reason:+ ($reason)} [code $code]." "$fix" \
    "$(jq -n --argjson s "$summary" --argjson e "$(echo "$resp" | jq -c '.error')" --arg r "$reason" '$s + {sent: false, pod_error: $e, reason: $r}')"
fi
sent_tx=$(echo "$resp" | jq -r '.result')

status='{"status":"not_found"}'
deadline=$(( $(date +%s) + wait_s ))
while :; do
  st=$(rpc pod_getTxStatus "[\"$sent_tx\"]" | jq -c '.result // empty' 2>/dev/null || true)
  [ -n "$st" ] && status="$st"
  [ "$(echo "$status" | jq -r '.status')" = finalized ] && break
  [ "$(date +%s)" -ge "$deadline" ] && break
  sleep 0.25
done

accepted=$(echo "$status" | jq 'if .status == "finalized" then .success else null end')
out=$(jq -n --argjson s "$summary" --arg tx "$sent_tx" --argjson st "$status" --argjson acc "$accepted" '
  {ok: ($acc != false), sent: true} + $s + {tx: $tx, tx_status: $st, accepted: $acc,
   next: (if $acc == true then "Accepted by pod. That is not filled: read the outcome after the order'"'"'s deadline round with GET /v1/clob/orders/ADDRESS (or triggers, activity)."
          elif $acc == false then "Pod executed the transaction and marked it failed. Read GET /v1/clob/activity/ADDRESS for the reason."
          else "Not finalized yet. Ask pod_getTxStatus again before sending anything with this nonce." end)}')
echo "$out"
[ "$accepted" != false ]
