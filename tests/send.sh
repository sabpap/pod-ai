#!/usr/bin/env bash
# Offline tests of scripts/pod-send.sh, against a local fake pod (tests/fake-rpc.mjs). Nothing reaches
# pod. Throwaway keys and keystores are made for the run in a private temp folder and deleted after.
# The macOS Keychain is never touched: a stand-in `security` command plays its part.
# Usage: tests/send.sh          Needs cast, jq, curl and Node.js.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SEND="$ROOT/.claude/skills/pod/scripts/pod-send.sh"
D=$(mktemp -d "${TMPDIR:-/tmp}/pod-send-test.XXXXXX"); chmod 700 "$D"
FAKE=""
cleanup() { [ -n "$FAKE" ] && kill "$FAKE" 2>/dev/null; rm -rf "$D"; }
trap cleanup EXIT

pass=0; failed=0
ok()   { pass=$((pass+1)); echo "ok   $1"; }
bad()  { failed=$((failed+1)); echo "FAIL $1${2:+: $2}"; }
check() {   # check NAME JQ_TEST FILE
  if jq -e "$2" "$3" >/dev/null 2>&1; then ok "$1"; else bad "$1" "$(head -c 400 "$3")"; fi
}
ALL="$D/all-output"; : > "$ALL"
run() {   # run OUTFILE [ENV=VALUE...] -- ARGS...: run pod-send.sh, keep its output for the secret scan
  local out="$1"; shift; local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  env ${envs[@]+"${envs[@]}"} "$SEND" "$@" > "$out" 2>"$out.err"; local rc=$?
  cat "$out" "$out.err" >> "$ALL"; return $rc
}

# --- the fake pod -----------------------------------------------------------------------------------

start_fake() {   # start_fake [ENV=VALUE...]: (re)start the fake with these settings
  [ -n "$FAKE" ] && kill "$FAKE" 2>/dev/null && wait "$FAKE" 2>/dev/null
  rm -f "$D/port"; : > "$D/log"
  env "$@" node "$ROOT/tests/fake-rpc.mjs" "$D/port" "$D/log" & FAKE=$!
  for _ in $(seq 1 50); do [ -s "$D/port" ] && break; sleep 0.1; done
  URL="http://127.0.0.1:$(cat "$D/port")"
}
sends() { grep -c eth_sendRawTransaction "$D/log" || true; }

# --- throwaway wallets --------------------------------------------------------------------------------

KEY=$(cast wallet new --json | jq -r '.data | if type=="array" then .[0] else . end | .private_key')
ADDR=$(cast wallet address --private-key "$KEY")
PW=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
(umask 077; printf '%s' "$PW" > "$D/pw")
mkdir -p "$D/ks"
cast wallet import testks --private-key "$KEY" --keystore-dir "$D/ks" --unsafe-password "$PW" >/dev/null 2>&1 \
  || { echo "could not make the throwaway keystore"; exit 1; }
# A stand-in for the macOS Keychain tool: knows one entry, foundry-keystore / testks.
mkdir -p "$D/bin"
cat > "$D/bin/security" <<EOF
#!/bin/sh
[ "\$1" = find-generic-password ] && [ "\$3" = foundry-keystore ] && [ "\$5" = testks ] && { printf '%s\n' "\$(cat "$D/pw")"; exit 0; }
exit 44
EOF
chmod 700 "$D/bin/security"
export -n POD_PRIVATE_KEY POD_KEYSTORE POD_KEYSTORE_DIR POD_KEYSTORE_PASSWORD_FILE 2>/dev/null
unset POD_PRIVATE_KEY POD_KEYSTORE POD_KEYSTORE_DIR POD_KEYSTORE_PASSWORD_FILE

BOOK=0x0000000000000000000000000000000000000000000000000000000000000007
SIG='submitOrder(bytes32,int256,uint256,uint8,uint128,uint128,uint8)'
DL=1795716900000000; TTL=$(( DL + 86400000000 ))
ARGS=("$BOOK" -10000000000000000 153900000000000000000 1 "$DL" "$TTL" 3)
CALLDATA=$(cast calldata "$SIG" "${ARGS[@]}")
start_fake

# --- help and arguments -----------------------------------------------------------------------------

"$SEND" --help | grep -q "Sign and send ONE transaction" && ok "help" || bad "help"
run "$D/o" POD_PRIVATE_KEY="$KEY" POD_RPC_URL="$URL" -- --dry-run 'notasignature' 1; check "a bad signature is refused" '.ok == false and .step == "args"' "$D/o"
run "$D/o" POD_PRIVATE_KEY="$KEY" POD_RPC_URL="$URL" -- --dry-run --data "$CALLDATA" "$SIG"; check "--data with a signature is refused" '.ok == false and .step == "args"' "$D/o"
run "$D/o" POD_PRIVATE_KEY="$KEY" POD_RPC_URL="$URL" -- --dry-run "$SIG" "$BOOK" 1; check "wrong number of arguments is refused at encoding" '.ok == false and .step == "encode"' "$D/o"
run "$D/o" POD_PRIVATE_KEY="$KEY" POD_RPC_URL="$URL" -- --dry-run --nonce x "$SIG" "${ARGS[@]}"; check "a bad nonce is refused" '.ok == false and .step == "args"' "$D/o"
run "$D/o" POD_PRIVATE_KEY="$KEY" POD_RPC_URL="$URL" -- --frobnicate; check "an unknown option is refused" '.ok == false and .step == "args"' "$D/o"

# --- the wallet check -------------------------------------------------------------------------------

run "$D/o" POD_KEYSTORE_DIR="$D/ks" POD_RPC_URL="$URL" -- --check
check "no wallet: refused, with the fix" '.ok == false and .step == "wallet" and (.fix | test("Never ask them to paste a private key"))' "$D/o"
check "no wallet: lists keystore names" '.keystores_found == ["testks"]' "$D/o"
run "$D/o" POD_PRIVATE_KEY="$KEY" POD_RPC_URL="$URL" -- --check
check "env key: check passes" ".ok == true and .wallet.type == \"env\" and .wallet.address == \"$ADDR\" and .network.writes_open == true and .next_nonce == 7" "$D/o"
run "$D/o" POD_KEYSTORE=testks POD_KEYSTORE_DIR="$D/ks" POD_KEYSTORE_PASSWORD_FILE="$D/pw" POD_RPC_URL="$URL" -- --check
check "keystore + password file: check passes" ".ok == true and .wallet.type == \"keystore\" and .wallet.password_from == \"file\" and (.wallet.address | ascii_downcase) == \"$(echo "$ADDR" | tr 'A-F' 'a-f')\"" "$D/o"
run "$D/o" PATH="$D/bin:$PATH" POD_KEYSTORE=testks POD_KEYSTORE_DIR="$D/ks" POD_RPC_URL="$URL" -- --check
check "keystore + Keychain (stand-in): check passes" '.ok == true and .wallet.password_from == "keychain"' "$D/o"
cp "$D/ks/testks" "$D/ks/other"
run "$D/o" PATH="$D/bin:$PATH" POD_KEYSTORE_DIR="$D/ks" POD_RPC_URL="$URL" -- --check --keystore other
check "keystore without a Keychain entry: refused with the command to add it" '.ok == false and (.fix | test("security add-generic-password -s foundry-keystore -a other -w"))' "$D/o"
rm -f "$D/ks/other"
(umask 077; printf 'wrong' > "$D/pw-wrong")
run "$D/o" POD_KEYSTORE=testks POD_KEYSTORE_DIR="$D/ks" POD_KEYSTORE_PASSWORD_FILE="$D/pw-wrong" POD_RPC_URL="$URL" -- --check
check "keystore with a wrong password: refused" '.ok == false and .step == "wallet"' "$D/o"
run "$D/o" POD_KEYSTORE=missing POD_KEYSTORE_DIR="$D/ks" POD_RPC_URL="$URL" -- --check
check "unknown keystore: refused, names the ones found" '.ok == false and .keystores_found == ["testks"]' "$D/o"
run "$D/o" POD_PRIVATE_KEY="$KEY" POD_KEYSTORE=testks POD_RPC_URL="$URL" -- --check
check "both wallets set: refused as ambiguous" '.ok == false and (.error | test("ambiguous"))' "$D/o"
run "$D/o" POD_PRIVATE_KEY="not-a-key-$PW" POD_RPC_URL="$URL" -- --check
check "a variable that is not a key: refused" '.ok == false and .step == "wallet"' "$D/o"
grep -q "not-a-key" "$D/o" && bad "the bad value is not echoed" || ok "the bad value is not echoed"
run "$D/o" MY_TEST_KEY="$KEY" POD_RPC_URL="$URL" -- --check --key-env MY_TEST_KEY
check "--key-env names another variable" '.ok == true and .wallet.env_var == "MY_TEST_KEY"' "$D/o"

# --- dry run: what is signed is what was asked ------------------------------------------------------

run "$D/dry" POD_PRIVATE_KEY="$KEY" POD_RPC_URL="$URL" -- --dry-run "$SIG" "${ARGS[@]}"
check "dry run: ok, not sent" '.ok == true and .dry_run == true and .sent == false' "$D/dry"
[ "$(sends)" = 0 ] && ok "dry run: nothing reached eth_sendRawTransaction" || bad "dry run sent something"
RAW=$(jq -r .raw_tx "$D/dry")
cast decode-tx "$RAW" > "$D/decoded"
check "decoded: EIP-1559 on chain 129302"     '.type == "0x2" and .chainId == "0x1f916"' "$D/decoded"
check "decoded: to the order book, no value"  '.to == "0x50d0000000000000000000000000000000000002" and .value == "0x0"' "$D/decoded"
check "decoded: the calldata asked for"       ".input == \"$CALLDATA\"" "$D/decoded"
check "decoded: signed by the wallet"         ".signer == \"$(echo "$ADDR" | tr 'A-F' 'a-f')\"" "$D/decoded"
check "decoded: the pending nonce (7)"        '.nonce == "0x7"' "$D/decoded"
[ "$(cast keccak "$RAW")" = "$(jq -r .tx "$D/dry")" ] && ok "tx hash is the hash of the signed transaction" || bad "tx hash"
args_back=$(cast decode-calldata "$SIG" "$(jq -r .input "$D/decoded")" | tr '\n' ' ')
case "$args_back" in *"-10000000000000000"*"153900000000000000000"*) ok "decoded arguments: negative size and price kept" ;; *) bad "decoded arguments" "$args_back" ;; esac
check "order id = keccak256(abi.encode(signer, nonce, 0))" ".order_id == \"$(cast keccak "$(cast abi-encode 'f(address,uint64,uint32)' "$ADDR" 7 0)")\"" "$D/dry"

run "$D/dry-ks" POD_KEYSTORE=testks POD_KEYSTORE_DIR="$D/ks" POD_KEYSTORE_PASSWORD_FILE="$D/pw" POD_RPC_URL="$URL" -- --dry-run "$SIG" "${ARGS[@]}"
[ "$(jq -r .raw_tx "$D/dry-ks")" = "$RAW" ] && ok "keystore signs the same bytes as the env key" || bad "keystore and env key differ"
run "$D/dry-data" POD_PRIVATE_KEY="$KEY" POD_RPC_URL="$URL" -- --dry-run --data "$CALLDATA"
[ "$(jq -r .raw_tx "$D/dry-data")" = "$RAW" ] && ok "--data signs the same bytes as SIGNATURE ARGS" || bad "--data differs"
run "$D/o" POD_PRIVATE_KEY="$KEY" POD_RPC_URL="$URL" -- --dry-run --nonce 42 'cancel(bytes32,bytes32,uint128)' "$BOOK" 0x"$(printf '%064x' 1)" "$DL"
check "--nonce is used, and a cancel has no new order id" '.nonce == 42 and .decoded.nonce == "0x2a" and (has("order_id") | not)' "$D/o"
INNER=$(cast calldata 'cancel(bytes32,bytes32,uint128)' "$BOOK" 0x"$(printf '%064x' 1)" "$DL")
run "$D/o" POD_PRIVATE_KEY="$KEY" POD_RPC_URL="$URL" -- --dry-run 'submitBatch(bytes[])' "[$INNER,$INNER]"
check "a batch encodes" ".ok == true and .calldata == \"$(cast calldata 'submitBatch(bytes[])' "[$INNER,$INNER]")\"" "$D/o"

# --- only pod staging -------------------------------------------------------------------------------

start_fake FAKE_CHAIN_ID=0x1
run "$D/o" POD_PRIVATE_KEY="$KEY" POD_RPC_URL="$URL" -- --dry-run "$SIG" "${ARGS[@]}"
check "chain id 1: refused" '.ok == false and .step == "network" and (.error | test("not pod staging"))' "$D/o"
run "$D/o" POD_PRIVATE_KEY="$KEY" POD_RPC_URL="$URL" -- "$SIG" "${ARGS[@]}"
check "chain id 1, real send: refused" '.ok == false and .step == "network"' "$D/o"
[ "$(sends)" = 0 ] && ok "wrong chain: nothing was sent" || bad "wrong chain: something was sent"
grep -q eth_estimateGas "$D/log" && bad "wrong chain: nothing was even signed" || ok "wrong chain: nothing was even signed"
run "$D/o" POD_PRIVATE_KEY="$KEY" POD_RPC_URL="http://127.0.0.1:9" -- --check
check "no network: refused" '.ok == false and .step == "network"' "$D/o"

# --- sending (to the fake) --------------------------------------------------------------------------

start_fake FAKE_TX_HASH="$(jq -r .tx "$D/dry")"
run "$D/o" POD_PRIVATE_KEY="$KEY" POD_RPC_URL="$URL" -- "$SIG" "${ARGS[@]}"
check "send: accepted, with pod's status" ".ok == true and .sent == true and .accepted == true and .tx == \"$(jq -r .tx "$D/dry")\" and .tx_status.status == \"finalized\"" "$D/o"
[ "$(grep eth_sendRawTransaction "$D/log" | jq -r '.params[0]')" = "$RAW" ] && ok "send: the bytes sent are the dry run's bytes" || bad "send: bytes differ from the dry run"
grep -q pod_getTxStatus "$D/log" && ok "send: asked pod_getTxStatus" || bad "send: no pod_getTxStatus"

start_fake FAKE_TX_SUCCESS=false
run "$D/o" POD_PRIVATE_KEY="$KEY" POD_RPC_URL="$URL" -- "$SIG" "${ARGS[@]}"; rc=$?
check "executed but failed: ok false, accepted false" '.ok == false and .accepted == false' "$D/o"
[ "$rc" = 1 ] && ok "executed but failed: exit 1" || bad "executed but failed: exit $rc"

start_fake FAKE_SEND=996
run "$D/o" POD_PRIVATE_KEY="$KEY" POD_RPC_URL="$URL" -- "$SIG" "${ARGS[@]}"
check "nonce clash (996): pod's error and the fix" '.ok == false and .pod_error.code == 996 and (.fix | test("nonce"))' "$D/o"
start_fake FAKE_SEND=3
run "$D/o" POD_PRIVATE_KEY="$KEY" POD_RPC_URL="$URL" -- "$SIG" "${ARGS[@]}"
check "revert (3): the reason is decoded" '.ok == false and .reason == "CLOB validation failed: Deadline is not aligned to auction interval"' "$D/o"
start_fake FAKE_SEND=-32025
run "$D/o" POD_PRIVATE_KEY="$KEY" POD_RPC_URL="$URL" -- "$SIG" "${ARGS[@]}"
check "region (-32025): named" '.ok == false and (.fix | test("region"))' "$D/o"

# --- secrets ----------------------------------------------------------------------------------------

if grep -qi -e "${KEY#0x}" "$ALL"; then bad "the private key never appears in any output"; else ok "the private key never appears in any output ($(wc -l < "$ALL" | tr -d ' ') lines checked)"; fi
if grep -q -e "$PW" "$ALL"; then bad "the keystore password never appears in any output"; else ok "the keystore password never appears in any output"; fi
left=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'pod-send.*' -newer "$D/pw" 2>/dev/null | wc -l | tr -d ' ')
[ "$left" = 0 ] && ok "no temp folder (with a password file) is left behind" || bad "$left temp folders left behind"

echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
