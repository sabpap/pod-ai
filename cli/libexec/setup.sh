#!/usr/bin/env bash
# Connect pod to pod staging and one wallet, in one call: setup steps 1 to 8. Spec: specs/02-setup.md.
#
#: pod setup: connect one wallet to pod staging, prove it can send, show or remove the connection.
#:
#: Usage:
#:   pod setup --keystore NAME [--yes | --skip-test]   connect a Foundry keystore wallet
#:   pod setup --env VARIABLE  [--yes | --skip-test]   connect a private key held in an environment variable
#:   pod setup wallets              list the keystores, and whether each has its password in the Keychain
#:   pod setup show                 the connected wallet (the profile), or "connected": false
#:   pod setup test                 plan the test transaction and stop ("needs_approval": true)
#:   pod setup test --yes           send the test transaction: a real order and its cancel
#:   pod setup test --dry-run       show the test transaction's plan; sends nothing
#:   pod setup disconnect           delete the profile; the wallet itself is not touched
#:   pod setup tools                check that cast, jq, curl and bc are installed (and Node.js for live)
#:   pod setup network              check that pod staging answers and is open for writes
#:
#: Pick the action from the request:
#:   "connect my wallet", "set up pod"     pod setup wallets, then pod setup --keystore NAME
#:   "use the key in POD_PRIVATE_KEY"      pod setup --env POD_PRIVATE_KEY
#:   "which wallet is connected?"          pod setup show
#:   "test my wallet again"                pod setup test, ask the person, then pod setup test --yes
#:   "disconnect", "use another wallet"    pod setup disconnect (then connect again). One wallet at a time
#:   "what are my settings?"               pod settings
#:
#: Wallet types:
#:   keystore  An encrypted Foundry keystore in ~/.foundry/keystores whose password is in the macOS
#:             Keychain (service foundry-keystore, account = the keystore's name).
#:   env       A private key in an environment variable of the shell that runs pod (default
#:             POD_PRIVATE_KEY). For servers and CI.
#:   Never ask for, read, print or store a password or a private key. If a keystore has no Keychain
#:   password, give the person the "fix" command and let them run it themselves.
#:
#: Connecting, step by step:
#:   1. pod setup wallets. "address" is often null: Foundry keystores do not store it in clear.
#:      Exactly one usable keystore: use it. Several: ask which. None: offer the env route.
#:   2. pod setup --keystore NAME. It checks the tools, checks pod answers and is open for writes,
#:      reads the address, signs a test message and verifies it, reads the account and saves the profile.
#:   3. Read "level" in the answer:
#:        connected, untested + needs_approval: true   funded; the test transaction waits for approval
#:        connected, untested                          funded; the test was skipped (--skip-test)
#:        connected, read-only                         the account has no cash on pod, so it cannot trade
#:        ready to trade                               everything passed, including the test transaction
#:        problem                                      the test transaction failed: see test_transaction.error
#:   4. The test transaction places a maker-only buy of the smallest size on the NVDA perp at half the
#:      oracle price (it cannot fill), then cancels it once it rests in the book. It takes about 15
#:      seconds and proves the wallet can trade. Show the person "plan" (wallet, market, size,
#:      price_usd, oracle_price_usd) and ask them to approve or deny it. Only on approve run
#:      pod setup test --yes. Anything else means: send nothing. The wallet stays connected but unproven.
#:      An agent working alone may pass --yes to pod setup only when its instructions allow sending.
#:   5. Report the level, the address, the wallet type, cash, open positions and orders, the test
#:      result with its two transaction hashes, and settings.in_words (changed with pod settings).
#:
#: Output fields (pod setup --keystore / --env):
#:   level, network, writes_open, address, wallet (keystore or env), account (cash_usd,
#:   withdrawable_usd, account_value_usd, open_positions, open_orders), test_transaction (null, or
#:   result, at, market, order_tx, cancel_tx, error), settings (approval, market_band_pct,
#:   default_ttl, in_words), profile (its path), note, and with needs_approval: true, the test's plan.
#:
#: Facts:
#:   The profile (~/.config/pod-plugin/profile.json, readable only by you) holds the network, the
#:   wallet type, the keystore or variable name and the address. Never a secret.
#:   Pod's fees are paid from the account's pod cash: an account with no cash cannot send anything.
#:   The test order expires by itself 5 minutes after its deadline, should the cancel fail.
#:   Pod error -32025 means "not available in your region": this wallet cannot trade from here.
#:   Pod staging is a test network with play money. It is reset from time to time, which wipes
#:   balances; after a reset, run the test again.
#:   POD_TEST_LAG_S (default 5) sets the seconds between sending the test order and its auction round.

source "$(dirname "$0")/lib.sh"
HERE="$(dirname "$0")"

wallet_opt=(); yes=false; skip=false
while [ $# -gt 0 ]; do
  case "$1" in
    --keystore|--env) wallet_opt=("$1" "${2:-}"); shift 2 ;;
    --yes) yes=true; shift ;;
    --skip-test) skip=true; shift ;;
    *) fail_usage setup "Unknown option $1." "Use --keystore NAME or --env VAR, plus --yes or --skip-test. See pod setup --help." ;;
  esac
done
[ ${#wallet_opt[@]} -eq 2 ] && [ -n "${wallet_opt[1]}" ] || fail setup "Name the wallet: --keystore NAME or --env VAR." "Run pod setup wallets to see the keystores."

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
MSG="pod setup check $(now_iso)"
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
    --argjson wallet "$(echo "$addr_json" | jq '{type}')" --argjson net "$net" --argjson acct "$account" --arg path "$PROFILE" \
    --argjson settings "$(settings_json)" '
    {ok: true, level: $level, network: $net.network, writes_open: $net.writes_open,
     address: $addr, wallet: $wallet.type, account: $acct, test_transaction: $test, settings: $settings, profile: $path}
    + (if $note == "" then {} else {note: $note} end)'
}

# 8 Test transaction
if ! $funded; then
  summary "connected, read-only" 'null' "The account has no cash on pod, so it cannot trade. Fund it, then run pod setup test."
  exit 0
fi
if $skip; then
  summary "connected, untested" 'null' "No test transaction was sent. Run pod setup test to prove the wallet can trade."
  exit 0
fi
if ! $yes; then
  t=$(run test-transaction.sh) || { echo "$t"; exit 1; }
  summary "connected, untested" 'null' "Waiting for approval of the test transaction." \
    | jq --argjson t "$t" '. + {needs_approval: true, plan: $t.plan,
        next: "Show the person the plan and ask them to approve or deny the test transaction. Only on approve, run: pod setup test --yes"}'
  exit 0
fi

t=$("$HERE/test-transaction.sh" --yes) || {
  summary "problem" "$(echo "$t" | jq '{result: "failed", error: .error}')" "$(echo "$t" | jq -r '.fix // ""')" \
    | jq '. + {ok: false, step: "test", error: .test_transaction.error}'
  exit 1
}
summary "ready to trade" "$(echo "$t" | jq 'del(.ok, .meaning)')" ""
