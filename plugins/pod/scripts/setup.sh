#!/usr/bin/env bash
# Connect the pod plugin to pod staging and one wallet, in one call. Runs setup steps 1 to 8.
#
# Usage:
#   setup.sh --keystore NAME [--yes | --skip-test]
#   setup.sh --env VAR       [--yes | --skip-test]
#
# Without --yes, setup stops before the test transaction and returns its plan with
# "needs_approval": true. The caller asks the user to approve or deny it and, only on approve, runs test-transaction.sh --yes.
# --skip-test saves the profile without sending anything.

source "$(dirname "$0")/lib.sh"
HERE="$(dirname "$0")"

wallet_opt=(); yes=false; skip=false
while [ $# -gt 0 ]; do
  case "$1" in
    --keystore|--env) wallet_opt=("$1" "${2:-}"); shift 2 ;;
    --yes) yes=true; shift ;;
    --skip-test) skip=true; shift ;;
    *) fail setup "Unknown option $1." "Use --keystore NAME or --env VAR, plus --yes or --skip-test." ;;
  esac
done
[ ${#wallet_opt[@]} -eq 2 ] && [ -n "${wallet_opt[1]}" ] || fail setup "Name the wallet: --keystore NAME or --env VAR." "Run list-wallets.sh to see the keystores."

# run STEP SCRIPT ARGS...: run a step; on failure print its JSON and stop.
run() {
  local out
  out=$("$HERE/$1" "${@:2}") || { echo "$out"; exit 1; }
  echo "$out"
}

# 1 Tools, 2 network
tools=$(run check-tools.sh) || { echo "$tools"; exit 1; }
net=$(run check-network.sh) || { echo "$net"; exit 1; }

# 3-4 Wallet and address
addr_json=$(run wallet.sh "${wallet_opt[@]}" address) || { echo "$addr_json"; exit 1; }
ADDR=$(echo "$addr_json" | jq -r '.address')

# 5 Signing check: sign a fixed message and verify it against the address. Nothing is sent.
MSG="pod plugin setup check $(now_iso)"
signed=$(run wallet.sh "${wallet_opt[@]}" sign-message "$MSG") || { echo "$signed"; exit 1; }
SIG=$(echo "$signed" | jq -r '.signature')
cast wallet verify --address "$ADDR" "$MSG" "$SIG" >/dev/null 2>&1 \
  || fail signing "The wallet's signature does not belong to $ADDR. The profile was not saved."

# 6 Account
bal=$(rest "/clob/balances/$ADDR") || fail account "Could not read the account's balances."
pos=$(rest "/clob/positions/$ADDR") || fail account "Could not read the account's positions."
orders=$(rest "/clob/orders/$ADDR?status=active&limit=500") || fail account "Could not read the account's orders."
CASH=$(to_dec "$(echo "$bal" | jq -r '.cash')")
WITHDRAWABLE=$(to_dec "$(echo "$bal" | jq -r '.withdrawable_cash')")
VALUE=$(to_dec "$(echo "$pos" | jq -r '.account_value')")
funded=$([ "$(bc_int "$CASH > 0")" = "1" ] && echo true || echo false)

# 7 Save the profile
if [ "${wallet_opt[0]}" = "--keystore" ]; then
  out=$(run profile.sh save --keystore "${wallet_opt[1]}" --address "$ADDR") || { echo "$out"; exit 1; }
else
  out=$(run profile.sh save --env "${wallet_opt[1]}" --address "$ADDR") || { echo "$out"; exit 1; }
fi

account=$(jq -n --arg cash "$(human "$CASH")" --arg w "$(human "$WITHDRAWABLE")" --arg v "$(human "$VALUE")" \
  --argjson p "$(echo "$pos" | jq '.positions | length')" --argjson o "$(echo "$orders" | jq '.total_count // (.orders | length)')" \
  '{cash_usd: $cash, withdrawable_usd: $w, account_value_usd: $v, open_positions: $p, open_orders: $o}')

summary() {   # summary LEVEL TEST_JSON NOTE
  jq -n --arg level "$1" --argjson test "$2" --arg note "$3" --arg addr "$ADDR" \
    --argjson wallet "$(echo "$addr_json" | jq '{type}')" --argjson net "$net" --argjson acct "$account" --arg path "$PROFILE" '
    {ok: true, level: $level, network: $net.network, writes_open: $net.writes_open,
     address: $addr, wallet: $wallet.type, account: $acct, test_transaction: $test, profile: $path}
    + (if $note == "" then {} else {note: $note} end)'
}

# 8 Test transaction
if ! $funded; then
  summary "connected, read-only" 'null' "The account has no cash on pod, so it cannot trade. Fund it, then run test-transaction.sh."
  exit 0
fi
if $skip; then
  summary "connected, untested" 'null' "No test transaction was sent. Run test-transaction.sh to prove the wallet can trade."
  exit 0
fi
if ! $yes; then
  t=$(run test-transaction.sh) || { echo "$t"; exit 1; }
  summary "connected, untested" 'null' "Waiting for approval of the test transaction." \
    | jq --argjson t "$t" '. + {needs_approval: true, plan: $t.plan,
        next: "Ask the user to approve or deny the test transaction. Only on approve, run test-transaction.sh --yes."}'
  exit 0
fi

t=$("$HERE/test-transaction.sh" --yes) || {
  summary "problem" "$(echo "$t" | jq '{result: "failed", error: .error}')" "$(echo "$t" | jq -r '.fix // ""')" \
    | jq '. + {ok: false, step: "test", error: .test_transaction.error}'
  exit 1
}
summary "ready to trade" "$(echo "$t" | jq 'del(.ok, .meaning)')" ""
