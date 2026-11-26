#!/usr/bin/env bash
# Read-only smoke test of the setup scripts against pod staging. Sends nothing.
# Uses a throwaway profile folder and a throwaway, unfunded private key, so the real profile and
# wallets are never touched.
#
# Usage: plugins/pod/tests/smoke.sh

set -uo pipefail
S="$(cd "$(dirname "$0")/../scripts" && pwd)"
export POD_PLUGIN_HOME="$(mktemp -d)"
trap 'rm -rf "$POD_PLUGIN_HOME"' EXIT

pass=0; failed=0
check() {   # check NAME JQ_EXPR COMMAND...
  local name="$1" expr="$2"; shift 2
  local out; out=$("$@" 2>/dev/null)
  if echo "$out" | jq -e "$expr" >/dev/null 2>&1; then pass=$((pass+1)); echo "ok   $name"
  else failed=$((failed+1)); echo "FAIL $name: $out"; fi
}

export SMOKE_KEY="$(cast wallet new --json | jq -r '.data | if type == "array" then .[0] else . end | .private_key')"

check "tools present"             '.ok'                                   "$S/check-tools.sh"
check "network is staging"        '.ok and .chain_id == 129302'           "$S/check-network.sh"
check "wallet list answers"       '.ok and (.keystores | type == "array")' "$S/list-wallets.sh"
check "no profile at start"       '.connected == false'                   "$S/profile.sh" show
check "unset variable refused"    '.ok == false and .step == "wallet"'    "$S/setup.sh" --env SMOKE_NOT_SET
check "bad key refused"           '.ok == false and .step == "wallet"'    env SMOKE_BAD=xyz "$S/setup.sh" --env SMOKE_BAD
check "missing keystore refused"  '.ok == false and .step == "wallet"'    "$S/setup.sh" --keystore smoke-no-such-wallet
check "unfunded key is read-only" '.ok and .level == "connected, read-only" and (.settings.in_words | test("asks before every trade"))' "$S/setup.sh" --env SMOKE_KEY
check "profile holds no key"      '.wallet.env_var == "SMOKE_KEY"'        "$S/profile.sh" show
if grep -q "${SMOKE_KEY#0x}" "$POD_PLUGIN_HOME/profile.json"; then failed=$((failed+1)); echo "FAIL key found in profile"; else pass=$((pass+1)); echo "ok   key not in profile file"; fi
check "unfunded test refused"     '.ok == false and .step == "test"'      "$S/test-transaction.sh" --dry-run

# Status, with the same unfunded throwaway wallet
check "status: unfunded is read-only"  '.level == "connected, read-only" and (.warnings | length) == 1' "$S/status.sh" --quick
check "status: shows settings"         '.settings.approval == "ask" and .settings.market_band_pct == 2 and (.summary | endswith("asks before trading"))' "$S/status.sh" --quick
check "status: full check signs"       '.check == "full" and .wallet.signs == true' "$S/status.sh"
check "status: cannot trade"           '[.capabilities[] | select(.name == "trade with this wallet")][0].can == false' "$S/status.sh" --quick
check "status: missing variable"       '.level == "problem" and .problems[0].check == "wallet"' env -u SMOKE_KEY "$S/status.sh" --quick
( source "$S/lib.sh"; record_send false true "" "Pod refused the transaction: not available in your region (-32025)." )
check "status: lasting refusal"        '.level == "problem" and .problems[0].check == "sending"' "$S/status.sh" --quick
( source "$S/lib.sh"; record_send true false "0xabc" "" )
check "status: accepted send clears"   '.level == "connected, read-only" and .proof.last_send.ok == true' "$S/status.sh" --quick
( source "$S/lib.sh"; record_send false false "" "nonce too low" )
check "status: passing refusal ignored" '.level == "connected, read-only"' "$S/status.sh" --quick

# Account, read on a public address (the dev wallet's), so nothing depends on the throwaway key
DEV=0x035A9E2f3ED8bAAD656E66BF3f0071da40DcDa70
skipped=0
check_hist() {   # like check, but skipped while pod says its history service (indexer) is down
  local name="$1" expr="$2"; shift 2
  local out; out=$("$@" 2>/dev/null)
  if echo "$out" | jq -e '.ok == false and (.error | test("indexer unavailable"))' >/dev/null 2>&1; then
    skipped=$((skipped+1)); echo "skip $name (pod's history service is down)"
  elif echo "$out" | jq -e "$expr" >/dev/null 2>&1; then pass=$((pass+1)); echo "ok   $name"
  else failed=$((failed+1)); echo "FAIL $name: $(echo "$out" | head -c 400)"; fi
}
check "account: overview"          '.ok and .view == "overview" and (.data.account_value_usd | type == "string") and (.computed | index("free_margin_usd"))' "$S/account.sh" "$DEV"
check "account: other address"     '.connected == false and .account == "'"$DEV"'"' "$S/account.sh" positions "$DEV"
check "account: positions list"    '.ok and (.data | type == "array") and (.count == (.data | length))' "$S/account.sh" positions "$DEV"
check "account: all orders, limit" '.ok and .count <= 2' "$S/account.sh" orders "$DEV" --status all --limit 2
check "account: triggers"          '.ok and (.data | type == "array")' "$S/account.sh" triggers "$DEV"
check "account: forced closes"     '.ok and (.data | type == "array")' "$S/account.sh" forced-closes "$DEV"
check "account: raw"               '.ok and (.raw | type == "array") and (.data == null)' "$S/account.sh" positions "$DEV" --raw
check_hist "account: trades"       '.ok and (.data | type == "array")' "$S/account.sh" trades "$DEV" --since 30d
check_hist "account: activity"     '.ok and (.data | all(.description | type == "string"))' "$S/account.sh" activity "$DEV" --limit 5
check_hist "account: results"      '.ok and (.data.lifetime | type == "object") and (.since | type == "string")' "$S/account.sh" results "$DEV"
check "account: unknown view"      '.ok == false' "$S/account.sh" balance "$DEV"
check "account: bad limit"         '.ok == false' "$S/account.sh" trades "$DEV" --limit 9000
check "account: bad address"       '.ok == false' "$S/account.sh" overview 0x1234
check "account: bad since"         '.ok == false' "$S/account.sh" trades "$DEV" --since yesterday
check "account: bad order status"  '.ok == false' "$S/account.sh" orders "$DEV" --status done

# Trading: plans and refusals only. The throwaway wallet is unfunded, so nothing could trade anyway.
check "settings: defaults"         '.settings.approval == "ask" and .settings.market_band_pct == 2 and .settings.default_ttl == "1d"' "$S/profile.sh" settings
check "settings: bad approval"     '.ok == false' "$S/profile.sh" set approval maybe
check "settings: band too wide"    '.ok == false' "$S/profile.sh" set market_band_pct 25
check "settings: set resting time" '.settings.default_ttl == "1h" and (.settings.in_words | test("rest 1 hour"))' "$S/profile.sh" set default_ttl 1h
check "settings: auto in words"    '.settings.in_words | startswith("trades without asking")' "$S/profile.sh" set approval auto
check "status: shows auto"         '.summary | endswith("trades without asking")' "$S/status.sh" --quick
"$S/profile.sh" set approval ask >/dev/null
"$S/profile.sh" set default_ttl 1d >/dev/null
check "trade: plan rounds safe"    '.ok and .needs_approval and .preview.price == "75.03" and .preview.size == "0.012345" and (.notes | length) >= 2' "$S/trade.sh" buy nvda 0.0123456789 --price 75.034
check "trade: sell rounds up"      '.preview.price == "75.04"' "$S/trade.sh" sell nvda 0.001 --price 75.031
check "trade: market order cap"    '.ok and (.preview.worst_price | type == "string") and (.notes[0] | test("plus 2%"))' "$S/trade.sh" buy nvda 0.001 --market
check "trade: own band"            '(.notes[0] | test("minus 1.5%"))' "$S/trade.sh" sell nvda 0.001 --market --band 1.5
check "trade: maker+ioc refused"   '.ok == false' "$S/trade.sh" buy nvda 0.001 --price 75 --maker-only --ioc
check "trade: unknown market"      '.ok == false and (.error | test("No market"))' "$S/trade.sh" buy nosuchthing 1 --price 1
check "trade: size below step"     '.ok == false' "$S/trade.sh" buy nvda 0.0000001 --price 75
check "trade: --send needs auto"   '.ok == false and (.error | test("ask"))' "$S/trade.sh" buy nvda 0.001 --price 75 --send
check "trade: unknown plan"        '.ok == false' "$S/trade.sh" send p00000000
pid=$("$S/trade.sh" buy nvda 0.001 --price 75 | jq -r .plan_id)
jq '.expires = 0' "$POD_PLUGIN_HOME/plans/$pid.json" > "$POD_PLUGIN_HOME/plans/x" && mv "$POD_PLUGIN_HOME/plans/x" "$POD_PLUGIN_HOME/plans/$pid.json"
check "trade: expired plan"        '.ok == false and (.error | test("expired"))' "$S/trade.sh" send "$pid"
check "trade: follow unsent plan"  '.ok == false' "$S/trade.sh" follow "$pid"
check "trade: close, no position"  '.ok == false and (.error | test("No open position"))' "$S/trade.sh" close nvda
check "trade: stop, no position"   '.ok == false' "$S/trade.sh" stop-loss nvda --trigger-price 100
check "trade: cancel-all, nothing" '.ok and .nothing_to_do' "$S/trade.sh" cancel-all
check "trade: cancel unknown"      '.ok == false' "$S/trade.sh" cancel 0x0000000000000000000000000000000000000000000000000000000000000001

check "disconnect"                '.disconnected'                         "$S/profile.sh" delete
check "trade: no wallet"          '.ok == false and (.fix | test("setup"))' "$S/trade.sh" buy nvda 1 --price 1
check "status: not set up"        '.level == "not set up" and .wallet == null and .settings.approval == "ask"' "$S/status.sh" --quick
check "settings: need a wallet"   '.ok == false' "$S/profile.sh" set approval auto
check "account: no wallet, no address" '.ok == false and (.fix | test("setup"))' "$S/account.sh"
check "send refused when not set up" '.ok == false'                       "$S/wallet.sh" send 0x0 "f()"

# No password file may be left behind. Needs a keystore with a Keychain password; skipped otherwise.
ks=$("$S/list-wallets.sh" | jq -r '[.keystores[] | select(.keychain_password)][0].name // empty')
if [ -n "$ks" ]; then
  tmp="$(mktemp -d)"
  TMPDIR="$tmp" "$S/wallet.sh" --keystore "$ks" address >/dev/null
  TMPDIR="$tmp" "$S/wallet.sh" --keystore "$ks" sign-message smoke >/dev/null
  left=$(ls -A "$tmp" | wc -l | tr -d ' ')
  rm -rf "$tmp"
  if [ "$left" = "0" ]; then pass=$((pass+1)); echo "ok   no password file left ($ks)"
  else failed=$((failed+1)); echo "FAIL $left password file(s) left behind ($ks)"; fi
else
  echo "skip no password file left (no keystore with a Keychain password)"
fi

echo "$pass passed, $failed failed${skipped:+, $skipped skipped}"
[ "$failed" -eq 0 ]
