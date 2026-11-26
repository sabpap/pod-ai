#!/usr/bin/env bash
# Read-only smoke test of the pod command against pod staging. Sends nothing.
# Uses a throwaway profile folder and a throwaway, unfunded private key, so the real profile and
# wallets are never touched.
#
# Usage: cli/tests/smoke.sh

set -uo pipefail
S="$(cd "$(dirname "$0")/../libexec" && pwd)"
POD="$(cd "$(dirname "$0")/.." && pwd)/pod"
export POD_PLUGIN_HOME="$(mktemp -d)"
trap 'rm -rf "$POD_PLUGIN_HOME"' EXIT

pass=0; failed=0
check() {   # check NAME JQ_EXPR COMMAND...
  local name="$1" expr="$2"; shift 2
  local out; out=$("$@" 2>/dev/null)
  if echo "$out" | jq -e "$expr" >/dev/null 2>&1; then pass=$((pass+1)); echo "ok   $name"
  else failed=$((failed+1)); echo "FAIL $name: $out"; fi
}

check_exit() {   # check_exit NAME CODE COMMAND...
  local name="$1" want="$2"; shift 2
  "$@" >/dev/null 2>&1; local got=$?
  if [ "$got" = "$want" ]; then pass=$((pass+1)); echo "ok   $name"
  else failed=$((failed+1)); echo "FAIL $name: exit $got, want $want"; fi
}

check_lines() {   # check_lines NAME JQ_EXPR COMMAND...: JQ_EXPR sees the array of every line printed
  local name="$1" expr="$2"; shift 2
  local out; out=$("$@" 2>/dev/null)
  if echo "$out" | jq -e -s "$expr" >/dev/null 2>&1; then pass=$((pass+1)); echo "ok   $name"
  else failed=$((failed+1)); echo "FAIL $name: $(echo "$out" | head -c 600)"; fi
}

export SMOKE_KEY="$(cast wallet new --json | jq -r '.data | if type == "array" then .[0] else . end | .private_key')"

check "tools present"             '.ok'                                   "$POD" setup tools
check "network is staging"        '.ok and .chain_id == 129302'           "$POD" setup network
check "wallet list answers"       '.ok and (.keystores | type == "array")' "$POD" setup wallets
check "no profile at start"       '.connected == false'                   "$POD" setup show
check "unset variable refused"    '.ok == false and .step == "wallet"'    "$POD" setup --env SMOKE_NOT_SET
check "bad key refused"           '.ok == false and .step == "wallet"'    env SMOKE_BAD=xyz "$POD" setup --env SMOKE_BAD
check "missing keystore refused"  '.ok == false and .step == "wallet"'    "$POD" setup --keystore smoke-no-such-wallet
check "unfunded key is read-only" '.ok and .level == "connected, read-only" and (.settings.in_words | test("asks before every trade"))' "$POD" setup --env SMOKE_KEY
check "profile holds no key"      '.wallet.env_var == "SMOKE_KEY"'        "$POD" setup show
if grep -q "${SMOKE_KEY#0x}" "$POD_PLUGIN_HOME/profile.json"; then failed=$((failed+1)); echo "FAIL key found in profile"; else pass=$((pass+1)); echo "ok   key not in profile file"; fi
check "unfunded test refused"     '.ok == false and .step == "test"'      "$POD" setup test --dry-run

# Status, with the same unfunded throwaway wallet
check "status: unfunded is read-only"  '.level == "connected, read-only" and (.warnings | length) == 1' "$POD" status --quick
check "status: shows settings"         '.settings.approval == "ask" and .settings.market_band_pct == 2 and (.summary | endswith("asks before trading"))' "$POD" status --quick
check "status: full check signs"       '.check == "full" and .wallet.signs == true' "$POD" status
check "status: cannot trade"           '[.capabilities[] | select(.name == "trade with this wallet")][0].can == false' "$POD" status --quick
check "status: missing variable"       '.level == "problem" and .problems[0].check == "wallet"' env -u SMOKE_KEY "$POD" status --quick
( export POD_CLI=1; source "$S/lib.sh"; record_send false true "" "Pod refused the transaction: not available in your region (-32025)." )
check "status: lasting refusal"        '.level == "problem" and .problems[0].check == "sending"' "$POD" status --quick
( export POD_CLI=1; source "$S/lib.sh"; record_send true false "0xabc" "" )
check "status: accepted send clears"   '.level == "connected, read-only" and .proof.last_send.ok == true' "$POD" status --quick
( export POD_CLI=1; source "$S/lib.sh"; record_send false false "" "nonce too low" )
check "status: passing refusal ignored" '.level == "connected, read-only"' "$POD" status --quick

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
check "account: overview"          '.ok and .view == "overview" and (.data.account_value_usd | type == "string") and (.computed | index("free_margin_usd"))' "$POD" account "$DEV"
check "account: other address"     '.connected == false and .account == "'"$DEV"'"' "$POD" account positions "$DEV"
check "account: positions list"    '.ok and (.data | type == "array") and (.count == (.data | length))' "$POD" account positions "$DEV"
check "account: all orders, limit" '.ok and .count <= 2' "$POD" account orders "$DEV" --status all --limit 2
check "account: triggers"          '.ok and (.data | type == "array")' "$POD" account triggers "$DEV"
check "account: forced closes"     '.ok and (.data | type == "array")' "$POD" account forced-closes "$DEV"
check "account: raw"               '.ok and (.raw | type == "array") and (.data == null)' "$POD" account positions "$DEV" --raw
check_hist "account: trades"       '.ok and (.data | type == "array")' "$POD" account trades "$DEV" --since 30d
check_hist "account: activity"     '.ok and (.data | all(.description | type == "string"))' "$POD" account activity "$DEV" --limit 5
check_hist "account: results"      '.ok and (.data.lifetime | type == "object") and (.since | type == "string")' "$POD" account results "$DEV"
check "account: unknown view"      '.ok == false' "$POD" account balance "$DEV"
check "account: bad limit"         '.ok == false' "$POD" account trades "$DEV" --limit 9000
check "account: bad address"       '.ok == false' "$POD" account overview 0x1234
check "account: bad since"         '.ok == false' "$POD" account trades "$DEV" --since yesterday
check "account: bad order status"  '.ok == false' "$POD" account orders "$DEV" --status done

# Trading: plans and refusals only. The throwaway wallet is unfunded, so nothing could trade anyway.
check "settings: defaults"         '.settings.approval == "ask" and .settings.market_band_pct == 2 and .settings.default_ttl == "1d"' "$POD" settings
check "settings: bad approval"     '.ok == false' "$POD" settings set approval maybe
check "settings: band too wide"    '.ok == false' "$POD" settings set market_band_pct 25
check "settings: set resting time" '.settings.default_ttl == "1h" and (.settings.in_words | test("rest 1 hour"))' "$POD" settings set default_ttl 1h
check "settings: auto in words"    '.settings.in_words | startswith("trades without asking")' "$POD" settings set approval auto
check "status: shows auto"         '.summary | endswith("trades without asking")' "$POD" status --quick
"$POD" settings set approval ask >/dev/null
"$POD" settings set default_ttl 1d >/dev/null
check "trade: plan rounds safe"    '.ok and .needs_approval and .preview.price == "75.03" and .preview.size == "0.012345" and (.notes | length) >= 2' "$POD" trade buy nvda 0.0123456789 --price 75.034
check "trade: sell rounds up"      '.preview.price == "75.04"' "$POD" trade sell nvda 0.001 --price 75.031
check "trade: market order cap"    '.ok and (.preview.worst_price | type == "string") and (.notes[0] | test("plus 2%"))' "$POD" trade buy nvda 0.001 --market
check "trade: own band"            '(.notes[0] | test("minus 1.5%"))' "$POD" trade sell nvda 0.001 --market --band 1.5
check "trade: maker+ioc refused"   '.ok == false' "$POD" trade buy nvda 0.001 --price 75 --maker-only --ioc
check "trade: unknown market"      '.ok == false and (.error | test("No market"))' "$POD" trade buy nosuchthing 1 --price 1
check "trade: size below step"     '.ok == false' "$POD" trade buy nvda 0.0000001 --price 75
check "trade: --send needs auto"   '.ok == false and (.error | test("ask"))' "$POD" trade buy nvda 0.001 --price 75 --send
check "trade: unknown plan"        '.ok == false' "$POD" trade send p00000000
pid=$("$POD" trade buy nvda 0.001 --price 75 | jq -r .plan_id)
jq '.expires = 0' "$POD_PLUGIN_HOME/plans/$pid.json" > "$POD_PLUGIN_HOME/plans/x" && mv "$POD_PLUGIN_HOME/plans/x" "$POD_PLUGIN_HOME/plans/$pid.json"
check "trade: expired plan"        '.ok == false and (.error | test("expired"))' "$POD" trade send "$pid"
check "trade: follow unsent plan"  '.ok == false' "$POD" trade follow "$pid"
check "trade: close, no position"  '.ok == false and (.error | test("No open position"))' "$POD" trade close nvda
check "trade: stop, no position"   '.ok == false' "$POD" trade stop-loss nvda --trigger-price 100
check "trade: cancel-all, nothing" '.ok and .nothing_to_do' "$POD" trade cancel-all
check "trade: cancel unknown"      '.ok == false' "$POD" trade cancel 0x0000000000000000000000000000000000000000000000000000000000000001
check "trade: size from dollars"   '.ok and .preview.size == "0.1" and any(.notes[]; test("= [$]10 at"))' "$POD" trade buy nvda --usd 10 --price 100
check "trade: dollars or size"     '.ok == false' "$POD" trade buy nvda 1 --usd 10 --price 100
check "trade: bad number reported" '.ok == false and (.error | test("not a plain"))' "$POD" trade buy nvda abc --price 100
check "trade: bad time reported"   '.ok == false and (.error | test("not a time"))' "$POD" trade buy nvda 0.01 --price 100 --rests 5y
check "trade: market value now"    '.preview.value_at_current_price_usd | type == "string"' "$POD" trade buy nvda 0.001 --market

# A person at a terminal is asked by pod trade send itself (approval "ask"). Nothing can be broadcast
# here: a "no" stops before signing, and after a "yes" the RPC points at a closed local port.
tty_run() {   # tty_run ANSWER COMMAND...: run in a pseudo-terminal, answer once; prints the output
  (sleep 2; printf '%s\n' "$1"; sleep 2) | script -q /dev/null "${@:2}" 2>&1 | tr -d '\r' | sed $'s/\x1b\\[[0-9;]*m//g'
}
state_of() { jq -r .state "$POD_PLUGIN_HOME/plans/$1.json"; }
DEAD_RPC=http://127.0.0.1:9
pid=$("$POD" trade buy nvda 0.001 --price 75 | jq -r .plan_id)
out=$(tty_run n "$POD" trade send "$pid")
if echo "$out" | grep -q 'Send it? \[y/N\]' && echo "$out" | grep -q 'buy 0.001 NVDA perp at \$75' \
   && echo "$out" | grep -q '"step": "approval"' && [ "$(state_of "$pid")" = planned ]; then
  pass=$((pass+1)); echo "ok   terminal: shows the plan, a no sends nothing"
else failed=$((failed+1)); echo "FAIL terminal no: $out"; fi
check_exit "terminal: a no exits 3"   3 bash -c '(sleep 2; echo n; sleep 2) | script -q /dev/null "$0" trade send "$1" >/dev/null 2>&1' "$POD" "$pid"
out=$(POD_TEST_RPC=$DEAD_RPC tty_run y "$POD" trade send "$pid")
if echo "$out" | grep -q 'Send it?' && ! echo "$out" | grep -q '"step": "approval"' \
   && echo "$out" | grep -q 'next transaction number. Nothing was sent' && [ "$(state_of "$pid")" = planned ]; then
  pass=$((pass+1)); echo "ok   terminal: a yes goes on to send (stopped here by a closed RPC port)"
else failed=$((failed+1)); echo "FAIL terminal yes: $out"; fi
out=$(POD_TEST_RPC=$DEAD_RPC "$POD" trade send "$pid" < /dev/null 2>&1)
if ! echo "$out" | grep -q 'Send it?' && echo "$out" | grep -q 'next transaction number' && [ "$(state_of "$pid")" = planned ]; then
  pass=$((pass+1)); echo "ok   no terminal: no question from pod (the agent asks, and the hook)"
else failed=$((failed+1)); echo "FAIL no terminal: $out"; fi
out=$(tty_run n "$POD" trade buy nvda 0.001 --price 75 --send)
if echo "$out" | grep -q 'Send it?' && echo "$out" | grep -q '"step": "approval"'; then
  pass=$((pass+1)); echo "ok   terminal: one-step --send asks too"
else failed=$((failed+1)); echo "FAIL terminal --send: $out"; fi

# Markets: read-only, no wallet needed
check "markets: list"              '.ok and .count > 10 and (.data[0].price | type == "string") and .more == false' "$POD" markets
check "markets: search"            '.count >= 1 and all(.data[]; .market | test("NVDA"))' "$POD" markets list nvda
check "markets: movers"            '.data | has("rising") and has("falling") and has("most_traded")' "$POD" markets movers
check "markets: perp leads with mark" '.data.price_kind == "mark" and (.data.summary | startswith("NVDA perp $")) and (.computed | index("book.spread"))' "$POD" markets market nvda
check "markets: spot leads with last" '.data.price_kind == "last traded" and .data.type == "spot"' "$POD" markets market "nvda spot"
check "markets: book levels"       '(.data.bids | length) <= 3 and (.data.asks | length) <= 3 and .data.buy_levels >= 0' "$POD" markets book nvda --depth 3
check "markets: cost of a size"    '(.data.estimate | length) == 2 and (.data.estimate_note | test("one price"))' "$POD" markets book nvda --size 1
check "markets: bars and summary"  '.count == 3 and .data.summary.bars == 3 and .resolution == "1d"' "$POD" markets bars nvda --resolution 1d --limit 3
check "markets: rounds by the half second" '.count == 6 and (.data | map(.time) | unique | length) == 6' "$POD" markets rounds nvda --limit 6
check "markets: unknown market"    '.ok == false and (.error | test("No market"))' "$POD" markets market nosuchthing
check "markets: never traded"      '.ok and .data.summary == "TEST spot: no price yet · no two-sided book · status disabled"' "$POD" markets market "TEST spot"
check "markets: no book yet"       '.ok == false and (.error | test("never traded"))' "$POD" markets book "TEST spot"
check "markets: bad bar size"      '.ok == false' "$POD" markets bars nvda --resolution 2h

# Live: short listeners against staging. Needs Node.js 22 or later; skipped otherwise.
if [ "$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)" -ge 22 ] 2>/dev/null; then
  check_lines "live: market, then time up" '.[0].event == "watching" and .[-1].event == "stopped" and any(.[]; .market == "NVDA perp" and .price_kind == "mark")' "$POD" live market nvda --for 3s --every 1s
  check_lines "live: condition met"      '.[-1].event == "condition met" and .[-1].condition == "mark_price > 0"' "$POD" live market nvda --until "mark > 0" --for 20s
  check_lines "live: each round once"    '[.[] | select(.market) | [.market, .time]] | length > 2 and length == (unique | length)' "$POD" live market nvda gold --every 0 --for 3s
  check_lines "live: raw, every market"  '[.[] | select(.raw) | .raw.orderbook_id] | unique | length == 2' "$POD" live market nvda gold --raw --every 1s --for 3s
  check "live: --for at most 30 days"    '.ok == false' "$POD" live market nvda --for 31d
  check_lines "live: positions snapshot" '.[1].account_value_usd | type == "string"' "$POD" live positions "$DEV" --for 2s
  check_lines "live: rounds counted"     'any(.[]; (.round | type) == "number" and .rounds_since_last_line >= 1)' "$POD" live rounds --every 1s --for 3s
  check "live: unknown field refused"    '.ok == false and (.error | test("no field"))' "$POD" live market nvda --until "colour = red"
  check "live: one account per channel"  '.ok == false' "$POD" live positions "$DEV" 0x752f038fa0aa50397deda3a7a56d6bc13a743c17
  check "live: nothing left running"     '.count == 0' "$POD" live list
else
  echo "skip live checks (Node.js 22 or later is not installed)"
fi

# The contract: exit codes, one entry point, fixes that name pod commands
check_exit "exit 0: ok"                 0 "$POD" status --quick
check_exit "exit 1: failed"             1 "$POD" trade buy nosuchthing 1 --price 1
check_exit "exit 2: unknown command"    2 "$POD" nosuchcommand
check_exit "exit 2: unknown option"     2 "$POD" account --nosuchoption
check_exit "exit 2: unknown view"       2 "$POD" account balance
check_exit "exit 2: script run directly" 2 "$S/trade.sh" send p00000000
check "script run directly is refused" '.ok == false and .step == "usage" and (.fix | test("pod help"))' "$S/status.sh"
check "pod wallet send is refused"     '.ok == false and .step == "usage" and (.fix | test("pod trade"))' "$POD" wallet send 0x0 "f()"
check "fix names a pod command"        '.fix | test("pod account orders")' "$POD" trade cancel 0x0000000000000000000000000000000000000000000000000000000000000001
check "next names a pod command"       '.next | test("^Show the person.*pod trade send p[0-9a-f]{8}$")' "$POD" trade buy nvda 0.001 --price 75
check_exit "--help anywhere prints the manual, sends nothing" 0 bash -c '"$0" trade send p00000000 --help | grep -q "^pod trade:"' "$POD"

check "disconnect"                '.disconnected'                         "$POD" setup disconnect
check "trade: no wallet"          '.ok == false and (.fix | test("setup"))' "$POD" trade buy nvda 1 --price 1
check "status: not set up"        '.level == "not set up" and .wallet == null and .settings.approval == "ask"' "$POD" status --quick
check "settings: need a wallet"   '.ok == false' "$POD" settings set approval auto
check "account: no wallet, no address" '.ok == false and (.fix | test("setup"))' "$POD" account
check "send refused when not set up" '.ok == false'                       env POD_CLI=1 "$S/wallet.sh" send 0x0 "f()"
check "live: no wallet, no address" '.ok == false and (.fix | test("setup"))' "$POD" live positions

# No password file may be left behind. Needs a keystore with a Keychain password; skipped otherwise.
ks=$("$POD" setup wallets | jq -r '[.keystores[] | select(.keychain_password)][0].name // empty')
if [ -n "$ks" ]; then
  tmp="$(mktemp -d)"
  TMPDIR="$tmp" POD_CLI=1 "$S/wallet.sh" --keystore "$ks" address >/dev/null
  TMPDIR="$tmp" POD_CLI=1 "$S/wallet.sh" --keystore "$ks" sign-message smoke >/dev/null
  left=$(ls -A "$tmp" | wc -l | tr -d ' ')
  rm -rf "$tmp"
  if [ "$left" = "0" ]; then pass=$((pass+1)); echo "ok   no password file left ($ks)"
  else failed=$((failed+1)); echo "FAIL $left password file(s) left behind ($ks)"; fi
else
  echo "skip no password file left (no keystore with a Keychain password)"
fi

echo "$pass passed, $failed failed${skipped:+, $skipped skipped}"
[ "$failed" -eq 0 ]
