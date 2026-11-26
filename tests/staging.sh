#!/usr/bin/env bash
# Read-only checks against pod staging: every REST route, JSON-RPC method and WebSocket channel the
# references name answers the way the references say. Also a pod-send.sh dry run with a throwaway key
# (signed, never sent) and the listener sample from live.md. Nothing is sent to pod.
# Usage: tests/staging.sh        Needs curl, jq, cast, Node.js 22 or later and the network.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SK="$ROOT/.claude/skills/pod"
N="$SK/scripts/pod-number.sh"
R=https://staging-rpc.podtestnet.dev; V=$R/v1
DEV=0x035A9E2f3ED8bAAD656E66BF3f0071da40DcDa70   # the dev wallet, a public account with positions, orders and triggers
NV=0x0000000000000000000000000000000000000000000000000000000000000007   # NVDA perp
D=$(mktemp -d "${TMPDIR:-/tmp}/pod-staging-test.XXXXXX"); LISTENER=""
cleanup() { [ -n "$LISTENER" ] && kill "$LISTENER" 2>/dev/null; rm -rf "$D"; }
trap cleanup EXIT

pass=0; failed=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { failed=$((failed+1)); echo "FAIL $1${2:+: $2}"; }
get() { curl -sS --max-time 20 -o "$D/b" -w '%{http_code}' "$V$1" 2>/dev/null || echo 000; }   # get PATH: HTTP code; body in $D/b
rest() {   # rest NAME PATH JQ_TEST
  local code; code=$(get "$2")
  if [ "$code" = 200 ] && jq -e "$3" "$D/b" >/dev/null 2>&1; then ok "$1"; else bad "$1" "$code $(head -c 200 "$D/b")"; fi
  cp "$D/b" "$D/last"
}
status() {   # status NAME PATH CODE [BODY_GREP]
  local code; code=$(get "$2")
  if [ "$code" = "$3" ] && { [ -z "${4:-}" ] || grep -q -- "$4" "$D/b"; }; then ok "$1"; else bad "$1" "$code $(head -c 200 "$D/b")"; fi
}
rpc() { curl -sS --max-time 15 -X POST "$R" -H 'content-type: application/json' -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" > "$D/r" 2>/dev/null; }
call() {   # call NAME METHOD PARAMS JQ_TEST
  rpc "$2" "$3"
  if jq -e "$4" "$D/r" >/dev/null 2>&1; then ok "$1"; else bad "$1" "$(head -c 200 "$D/r")"; fi
}

# --- REST: markets -----------------------------------------------------------------------------------
rest "/clob/status gives solution_now in microseconds" /clob/status '.solution_now | (type == "number" and (tostring | length) == 16)'
NOW=$(jq -r .solution_now "$D/last")
rest "/clob/markets: an array of markets with their rules" /clob/markets \
  'type == "array" and length > 10 and all(.[]; has("id") and has("status") and has("market_type") and has("tick_precision") and has("lot_size") and has("maker_fee"))'
cp "$D/last" "$D/markets"
jq -e --arg id "$NV" '.[] | select(.base_token_symbol == "NVDA" and .market_type == "perp") | .id == $id' "$D/markets" >/dev/null \
  && ok "NVDA perp's market id is 0x…07" || bad "NVDA perp's market id"
jq -e 'all(.[]; .auction_interval_us == 500000)' "$D/markets" >/dev/null && ok "every market's auction_interval_us is 500000" || bad "auction intervals"
jq -e '[.[].market_type] | unique == ["perp", "spot"]' "$D/markets" >/dev/null && ok "market_type is perp or spot in the market list" || bad "market types"
jq -e 'any(.[]; .market_type == "spot" and (.base_token_symbol | endswith("x")))' "$D/markets" >/dev/null && ok "spot symbols end in x" || bad "spot symbols"
jq -e '.[] | select(.id == "'$NV'") | .tick_precision == "10000000000000000" and .lot_size == "1000000000000" and (.maker_fee | test("^0\\.[0-9]+$")) and (.max_leverage | type == "number") and .funding_window_us == 28800000000' "$D/markets" >/dev/null \
  && ok "NVDA rules: steps scaled by 10^18, fee a plain fraction, 8-hour funding window" || bad "NVDA rules"
rest "/clob/markets/stats: solution_now and markets[]" /clob/markets/stats \
  '(.solution_now | type == "number") and (.markets | length > 10) and all(.markets[]; has("orderbook_id") and has("volume_24h"))'
jq -e --arg id "$NV" '.markets[] | select(.orderbook_id == $id) | (.price_change_24h | type == "number") and (.mark_price | test("^[0-9]+$")) and has("oracle_price") and has("funding_rate") and has("open_interest")' "$D/last" >/dev/null \
  && ok "NVDA stats: decimal-string prices, change in basis points (a number)" || bad "NVDA stats"
rest "/clob/orderbook/{id}?depth=2: buys and sells keyed by decimal price, hex volumes" "/clob/orderbook/$NV?depth=2" \
  '(.buys | keys | all(test("^[0-9]+$"))) and (.buys | to_entries | all(.value.volume | startswith("0x"))) and has("buys_count") and has("timestamp") and (.clearing_price | startswith("0x"))'
jq -e '(.buys | keys | map(tonumber) | max) < (.sells | keys | map(tonumber) | min)' "$D/last" >/dev/null && ok "best bid (highest buys key) is below best ask (lowest sells key)" || bad "book order"
status "/clob/orderbook of a market that never cleared: 404 no orderbook snapshot yet" "/clob/orderbook/0x$(printf '%064x' 1048575)" 404 "no orderbook snapshot yet"
rest "/clob/candles/{id}: closed bars, hex prices, range in microseconds" "/clob/candles/$NV?resolution=1h&limit=3" \
  '(.candles | length >= 1) and (.candles[0].open | startswith("0x")) and (.range.from_us | type == "number") and has("solution_now_us")'
FROM_US=$(jq -r .range.from_us "$D/last")
rest "candles page back with to = range.from_us / 1000000 (seconds)" "/clob/candles/$NV?resolution=1h&limit=2&to=$(( FROM_US / 1000000 ))" \
  "all(.candles[]; .timestamp < $FROM_US)"
rest "/clob/solutions?orderbook: per-round rows, newest first" "/clob/solutions?orderbook=$NV&limit=3" \
  '(.solutions | length == 3) and (.solutions[0].mark_price | startswith("0x")) and (.solutions[0].timestamp > .solutions[2].timestamp)'
OLDEST=$(jq '[.solutions[].timestamp] | min' "$D/last")
rest "solutions page back with until_us" "/clob/solutions?orderbook=$NV&limit=2&until_us=$OLDEST" "all(.solutions[]; .timestamp < $OLDEST)"

# --- REST: account -----------------------------------------------------------------------------------
rest "/clob/positions/{a}: account value, cash, positions, timestamp" "/clob/positions/$DEV" \
  'has("account_value") and has("cash") and has("net_deposits") and has("withdrawable_cash") and has("total_unrealized_pnl") and (.timestamp | type == "number") and (.positions | type == "array")'
jq -e 'all(.positions[]; (.entry_price | startswith("0x")) and (.size | test("^-?[0-9]+$")) and has("liquidation_price") and has("funding_accrued") and (.side == "long" or .side == "short"))' "$D/last" >/dev/null \
  && ok "positions: hex prices, signed decimal sizes, side long or short" || bad "position fields"
if [ "$(jq '.positions | length' "$D/last")" -gt 0 ]; then
  e=$($N from-pod "$(jq -r '.positions[0].entry_price' "$D/last")")
  case "$e" in *.*|[0-9]*) ok "an entry price converts to a plain decimal ($e)" ;; *) bad "entry price conversion" "$e" ;; esac
fi
rest "/clob/positions with ?timestamp= (freshness) answers" "/clob/positions/$DEV?timestamp=$NOW" '.timestamp >= '"$NOW"
status "a timestamp far in the future: 503" "/clob/markets/stats?timestamp=99999999999999999" 503
rest "/clob/balances/{a}: cash, withdrawable, holdings" "/clob/balances/$DEV" 'has("cash") and has("withdrawable_cash") and (.balances | type == "array") and has("timestamp")'
rest "/clob/orders/{a}?status=active" "/clob/orders/$DEV?status=active&limit=1" 'has("orders") and has("next_cursor") and has("total_count")'
rest "/clob/orders/{a}: cursor paging" "/clob/orders/$DEV?limit=2" '(.orders | length == 2) and (.next_cursor | type == "string")'
CUR=$(jq -r .next_cursor "$D/last"); FIRST=$(jq -r '.orders[0].order_id' "$D/last")
rest "orders: the next page via cursor is different" "/clob/orders/$DEV?limit=2&cursor=$CUR" "(.orders | length >= 1) and all(.orders[]; .order_id != \"$FIRST\")"
rest "orders: offset mode" "/clob/orders/$DEV?limit=1&offset=1" '(.orders | length == 1) and .next_cursor == null'
rest "orders: an order's fields" "/clob/orders/$DEV?limit=1" \
  '.orders[0] | has("order_id") and has("tx_hash") and has("nonce") and (.price | startswith("0x")) and (.initial_size | test("^-?[0-9]+$")) and (.deadline | type == "string") and (.end | type == "number") and has("included_batch") and has("effective_price") and (.market_type == "perpetual" or .market_type == "spot")'
O_ID=$(jq -r '.orders[0].order_id' "$D/last"); O_N=$(jq -r '.orders[0].nonce' "$D/last"); O_TX=$(jq -r '.orders[0].tx_hash' "$D/last")
[ "$(cast keccak "$(cast abi-encode 'f(address,uint64,uint32)' "$DEV" "$O_N" 0)")" = "$O_ID" ] \
  && ok "order id = keccak256(abi.encode(signer, nonce, 0)), on a real order" || bad "order id formula"
jq -e '.orders[0] | (.end - (.deadline | tonumber)) > 0' "$D/last" >/dev/null && ok "an order's end is absolute: deadline + resting time" || bad "absolute end"
UNTIL_S=$(( $(jq -r '.orders[0].deadline' "$D/last") / 1000000 ))
rest "orders: until is in seconds" "/clob/orders/$DEV?limit=1&until=$UNTIL_S" '(.orders | length) == 1'
rest "orders: ?timestamp= (freshness) answers" "/clob/orders/$DEV?limit=1&timestamp=$NOW" '.solution_now >= '"$NOW"
status "orders: an unknown status is a 400" "/clob/orders/$DEV?status=open" 400
rest "/clob/fills/{a}: fills with hex amounts, no side field" "/clob/fills/$DEV?limit=2" \
  '(.fills | length >= 1) and all(.fills[]; has("initial_size") and (.price | startswith("0x")) and (has("side") | not) and (.timestamp | type == "number"))'
T0=$(jq '[.fills[].timestamp] | min' "$D/last")
rest "fills: the window [from_us, to_us)" "/clob/fills/$DEV?limit=5&to_us=$T0" "all(.fills[]; .timestamp < $T0)"
rest "/clob/triggers/{a}: armed triggers, cursor paging" "/clob/triggers/$DEV?limit=1" \
  'has("triggers") and has("total_count") and has("next_cursor") and all(.triggers[]; (.trigger_type == "stop_loss" or .trigger_type == "take_profit") and (.trigger_price | startswith("0x")))'
rest "/clob/backstop-transfers/{a}" "/clob/backstop-transfers/$DEV" 'has("backstop_transfers") and has("total_count")'
rest "backstop-transfers paged" "/clob/backstop-transfers/$DEV?limit=1" 'has("backstop_transfers")'
rest "/clob/activity/{a}: rounds keyed by microseconds, next" "/clob/activity/$DEV?limit=5&activity_types=order,fill" \
  '(.activity | keys | all(test("^[0-9]{16}$"))) and has("next") and has("solution_now") and ([.activity[][] | .k] | all(. == "order" or . == "fill"))'
NEXT=$(jq -r '.next // empty' "$D/last")
[ -n "$NEXT" ] && rest "activity: older page with to = next" "/clob/activity/$DEV?limit=5&to=$NEXT" "(.activity | keys | all(tonumber <= $NEXT))"
status "activity: from after to is a 422" "/clob/activity/$DEV?from=2&to=1" 422
status "activity: an unknown kind is a 400" "/clob/activity/$DEV?activity_types=funding" 400
rest "/accounts/{a}/nonce-slots: watermark and bitmap" "/accounts/$DEV/nonce-slots" '(.watermark | type == "number") and (.finalized | startswith("0x")) and has("solution_now")'

# --- REST: network ---------------------------------------------------------------------------------
rest "/transactions: newest first, decoded" "/transactions?limit=2" '(.transactions | length == 2) and has("next_offset") and (.transactions[0].decoded | has("function"))'
rest "/tx/{hash}: one transaction, decoded with its order id" "/tx/$O_TX" ".decoded.order_id == \"$O_ID\""
status "/tx of an unknown hash: 404" "/tx/0x$(printf '%064x' 1)" 404

# --- JSON-RPC --------------------------------------------------------------------------------------
call "eth_chainId is 0x1f916 (129302)" eth_chainId '[]' '.result == "0x1f916"'
call "pod_status: read_only and paused, both false" pod_status '[]' '.result.read_only == false and .result.paused == false'
call "eth_getTransactionCount pending: hex nonce" eth_getTransactionCount "[\"$DEV\",\"pending\"]" '.result | startswith("0x")'
call "pod_getNonceSlots: same as the REST nonce window" pod_getNonceSlots "[\"$DEV\"]" '.result | has("watermark") and has("finalized")'
call "pod_getAccountDiagnostics: is_locked, needs_recovery, equivocating" pod_getAccountDiagnostics "[\"$DEV\"]" \
  '.result | (.is_locked | type == "boolean") and (.needs_recovery | type == "boolean") and (.equivocating | type == "boolean")'
call "pod_getTxStatus of a real order transaction: finalized, success" pod_getTxStatus "[\"$O_TX\"]" '.result.status == "finalized" and .result.success == true'
call "pod_getTxStatus of an unknown hash: not_found" pod_getTxStatus "[\"0x$(printf '%064x' 1)\"]" '.result.status == "not_found"'
call "eth_blockNumber: hex round number" eth_blockNumber '[]' '.result | startswith("0x")'
call "eth_getBlockByNumber: timestamp is hex seconds" eth_getBlockByNumber '["latest",false]' \
  "(.result.timestamp | ltrimstr(\"0x\") | length) <= 9 and .result.number != null"

# --- every route and method the references name was checked above ----------------------------------
TESTED_ROUTES="/clob/status /clob/markets /clob/markets/stats /clob/orderbook /clob/candles /clob/solutions /clob/positions /clob/balances /clob/orders /clob/fills /clob/triggers /clob/backstop-transfers /clob/activity /accounts /transactions /tx"
for r in $(grep -oh -E '/(clob/[a-z-]+(/stats)?|accounts/|transactions|tx/)' "$SK"/references/*.md "$SK/SKILL.md" | sed 's:/$::' | sort -u); do
  case " $TESTED_ROUTES " in *" $r "*) ok "named in the manual and checked: $r" ;; *) bad "named in the manual but not checked" "$r" ;; esac
done
TESTED_METHODS="eth_chainId pod_status eth_getTransactionCount pod_getNonceSlots pod_getAccountDiagnostics pod_getTxStatus eth_blockNumber eth_getBlockByNumber eth_subscribe eth_unsubscribe eth_subscription eth_sendRawTransaction"
WS_CHANNELS="pod_markets pod_orderbook pod_candles pod_orders_v2 pod_activity pod_positions pod_triggers pod_receipts pod_orders pod_withdrawals pod_transfers"
for m in $(grep -oh -E '\b(eth|pod)_[A-Za-z0-9_]+' "$SK"/references/*.md "$SK/SKILL.md" | grep -vx 'pod_error' | sort -u); do   # pod_error: a field of pod-send.sh's answer
  case " $TESTED_METHODS $WS_CHANNELS " in *" $m "*) ok "named in the manual and checked: $m" ;; *) bad "named in the manual but not checked" "$m" ;; esac
done
# eth_sendRawTransaction is never called here: it is checked against the fake pod in tests/send.sh.

# --- pod-send.sh dry run on staging with a throwaway key (signed, not sent) ----------------------------
KEY=$(cast wallet new --json | jq -r '.data | if type=="array" then .[0] else . end | .private_key')
DL=$(( ( $($N us now) + 5000000 + 499999 ) / 500000 * 500000 ))
POD_PRIVATE_KEY="$KEY" "$SK/scripts/pod-send.sh" --check > "$D/check"
jq -e '.ok and .network.chain_id == 129302 and .network.writes_open == true and .next_nonce == 0' "$D/check" >/dev/null \
  && ok "pod-send.sh --check on staging (throwaway key)" || bad "pod-send.sh --check on staging" "$(cat "$D/check")"
POD_PRIVATE_KEY="$KEY" "$SK/scripts/pod-send.sh" --dry-run 'submitOrder(bytes32,int256,uint256,uint8,uint128,uint128,uint8)' \
  "$NV" 10000000000000000 75030000000000000000 0 "$DL" $(( DL + 86400000000 )) 4 > "$D/dry"
jq -e '.ok and .dry_run and (.sent | not) and .decoded.chainId == "0x1f916" and .decoded.type == "0x2" and .nonce == 0' "$D/dry" >/dev/null \
  && ok "pod-send.sh --dry-run on staging: signed for chain 129302, not sent" || bad "dry run on staging" "$(head -c 300 "$D/dry")"
grep -qi "${KEY#0x}" "$D/check" "$D/dry" && bad "the key appears in the output" || ok "the key does not appear in the output"
call "the dry run's transaction is unknown to pod (it was not sent)" pod_getTxStatus "[\"$(jq -r .tx "$D/dry")\"]" '.result.status == "not_found"'

# --- WebSocket channels -------------------------------------------------------------------------------
node "$ROOT/tests/staging-live.mjs" "$DEV" > "$D/ws" 2>&1
grep -E '^(ok|FAIL)' "$D/ws"
pass=$(( pass + $(grep -c '^ok' "$D/ws") )); failed=$(( failed + $(grep -c '^FAIL' "$D/ws") ))

# --- the listener sample in live.md runs as written ---------------------------------------------------
awk '/^```js$/ { on = 1; next } /^```$/ { on = 0 } on' "$SK/references/live.md" > "$D/listen.mjs"
node "$D/listen.mjs" pod_positions "{\"account\":\"$DEV\"}" "/clob/positions/$DEV" > "$D/listen.out" 2>&1 & LISTENER=$!
sleep 6; kill "$LISTENER" 2>/dev/null; wait "$LISTENER" 2>/dev/null; LISTENER=""
if [ "$(head -1 "$D/listen.out" | jq -r 'has("rest")' 2>/dev/null)" = true ] && [ "$(sed -n 2p "$D/listen.out" | jq -r '.account' 2>/dev/null)" = "$(echo "$DEV" | tr 'A-F' 'a-f')" ]; then
  ok "live.md's listener: REST state, then the live snapshot from since"
else bad "live.md's listener" "$(head -c 300 "$D/listen.out")"; fi

echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
