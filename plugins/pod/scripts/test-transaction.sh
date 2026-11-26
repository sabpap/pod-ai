#!/usr/bin/env bash
# Setup step 8: prove the connected wallet can really transact on pod.
# Sends one maker-only buy order on the NVDA perp at half the oracle price (it cannot fill), waits
# until it rests in the book, cancels it, and waits until it is cancelled. Saves the result in the
# profile. The order also expires by itself 5 minutes after its deadline, should the cancel fail.
#
# Usage:
#   test-transaction.sh              show the plan and stop ("needs_approval": true)
#   test-transaction.sh --yes        send it
#   test-transaction.sh --dry-run    show the plan and stop (a dry run)
#
# Environment: POD_TEST_LAG_S (default 5) seconds between sending and the order's auction round.

source "$(dirname "$0")/lib.sh"
HERE="$(dirname "$0")"

yes=false; dry=false
for a in "$@"; do
  case "$a" in
    --yes) yes=true ;;
    --dry-run) dry=true ;;
    *) fail test "Unknown option $a." "Use --yes or --dry-run." ;;
  esac
done

LAG_US=$(( ${POD_TEST_LAG_S:-5} * 1000000 ))
REST_FOR_US=300000000   # the order's own expiry: 5 minutes after its deadline

profile_exists || fail test "No wallet is connected." "Run /pod:setup first."
ADDR=$(profile_get '.wallet.address')

# Record a failed test in the profile, then fail.
test_failed() {
  local err="$1" fix="${2:-}"
  jq -n --arg at "$(now_iso)" --arg e "$err" --arg o "${ORDER_TX:-}" --arg c "${CANCEL_TX:-}" '
    {result: "failed", at: $at, market: "NVDA perp", error: $e,
     order_tx: (if $o == "" then null else $o end), cancel_tx: (if $c == "" then null else $c end)}' \
    | "$HERE/profile.sh" set-test >/dev/null || true
  fail test "$err" "$fix"
}

aligned_deadline() {   # the first auction boundary at least LAG_US from now
  local t=$(( $(now_us) + LAG_US ))
  echo $(( (t + AUCTION_US - 1) / AUCTION_US * AUCTION_US ))
}

wait_final() {   # wait_final TX: until pod_getTxStatus says finalized; prints the status object
  local i st
  for i in $(seq 1 40); do
    st=$(rpc_result pod_getTxStatus "[\"$1\"]" 2>/dev/null || echo '{}')
    if [ "$(echo "$st" | jq -r '.status // empty')" = "finalized" ]; then echo "$st"; return 0; fi
    sleep 0.5
  done
  return 1
}

order_status() {   # order_status MARKET_ID ORDER_ID: the order's status, or empty if not listed yet
  rest "/clob/orders/$ADDR?orderbook=$1&limit=50" 2>/dev/null \
    | jq -r --arg id "$2" '.orders[]? | select((.order_id | ascii_downcase) == ($id | ascii_downcase)) | .status' | head -1
}

wait_status() {   # wait_status MARKET_ID ORDER_ID DEADLINE_US WANTED...: poll until the status is one of WANTED
  local book="$1" id="$2" until_us=$(( $3 + 15000000 )) s w
  shift 3
  while [ "$(now_us)" -le "$until_us" ]; do
    s=$(order_status "$book" "$id")
    for w in "$@"; do [ "$s" = "$w" ] && { echo "$s"; return 0; }; done
    case "$s" in filled|expired|margin_canceled|self_trade_canceled|post_only_refused|invalid) echo "$s"; return 1 ;; esac
    sleep 1
  done
  echo "${s:-not listed}"
  return 1
}

# --- checks -----------------------------------------------------------------------------------------

require_staging
state=$(rpc_result pod_status '[]') || fail test "Pod did not answer pod_status." "Try again later."
[ "$(echo "$state" | jq '.read_only or .paused')" = "false" ] || fail test "Pod is paused or read-only right now, so nothing can be sent."

cash=$(to_dec "$(rest "/clob/balances/$ADDR" | jq -r '.cash')")
[ "$(bc_int "$cash > 0")" = "1" ] || fail test "The account has no cash on pod, so it cannot trade." "Fund the wallet, then run the test again."

# --- the order ----------------------------------------------------------------------------------------

markets=$(rest /clob/markets) || fail test "Could not read the market list."
market=$(echo "$markets" | jq -c '
  ([.[] | select(.market_type == "perp" and .status == "active" and .base_token_symbol == "NVDA")][0])
  // ([.[] | select(.market_type == "perp" and .status == "active")][0]) // empty')
[ -n "$market" ] || fail test "Pod lists no active perp market to test with."
BOOK=$(echo "$market" | jq -r '.id')
NAME=$(echo "$market" | jq -r '.name')
TICK=$(to_dec "$(echo "$market" | jq -r '.tick_precision')")
LOT=$(to_dec "$(echo "$market" | jq -r '.lot_size')")

ob=$(rest "/clob/orderbook/$BOOK?depth=1") || fail test "Could not read the $NAME order book."
ref=$(echo "$ob" | jq -r '.oracle_price // .clearing_price // empty')
[ -n "$ref" ] && [ "$ref" != "null" ] || fail test "$NAME has no oracle or last price to set a safe test price from."
REF=$(to_dec "$ref")
PRICE=$(bc_int "($REF / 2) / $TICK * $TICK")
SIZE=$(bc_int "(10^15 + $LOT - 1) / $LOT * $LOT")   # 0.001 of the asset, rounded up to the size step

next_nonce test "Try again in a moment."
NONCE=$NEXT_NONCE
ORDER_ID=$(cast keccak "$(cast abi-encode 'f(address,uint64,uint32)' "$ADDR" "$NONCE" 0)")
DEADLINE=$(aligned_deadline)
END=$(( DEADLINE + REST_FOR_US ))

plan=$(jq -n --arg addr "$ADDR" --arg market "$NAME" --arg book "$BOOK" \
  --arg size "$(human "$SIZE")" --arg price "$(human "$PRICE")" --arg ref "$(human "$REF")" \
  --arg notional "$(human "$(bc_int "$SIZE * $PRICE / 10^18")")" \
  --arg nonce "$NONCE" --arg id "$ORDER_ID" --arg dl "$DEADLINE" --arg end "$END" '
  {wallet: $addr, market: $market, market_id: $book, side: "buy", type: "limit, maker-only",
   size: $size, price_usd: $price, oracle_price_usd: $ref, order_value_usd: $notional,
   nonce: ($nonce | tonumber), order_id: $id, deadline_us: ($dl | tonumber), expires_us: ($end | tonumber),
   then: "cancel it as soon as it rests in the book",
   cost: "two transactions; staging charged no fee for them when tested on 2026-11-26",
   why_it_cannot_fill: "maker-only at half the oracle price: pod refuses it rather than trade"}')

if $dry; then
  jq -n --argjson p "$plan" '{ok: true, dry_run: true, plan: $p}'
  exit 0
fi
if ! $yes; then
  jq -n --argjson p "$plan" '{ok: true, needs_approval: true, plan: $p,
    next: "Ask the user to approve or deny the test transaction. Only on approve, run test-transaction.sh --yes."}'
  exit 0
fi

# --- send, rest, cancel ----------------------------------------------------------------------------------

sent=$("$HERE/wallet.sh" send "$ORDERBOOK" "$SUBMIT_ORDER" "$BOOK" "$SIZE" "$PRICE" 0 "$DEADLINE" "$END" "$FLAG_POST_ONLY" --nonce "$NONCE") \
  || test_failed "$(echo "$sent" | jq -r '.error // "The order could not be sent."')"
ORDER_TX=$(echo "$sent" | jq -r '.tx')

st=$(wait_final "$ORDER_TX") || test_failed "The order $ORDER_TX was not finalized within 20 seconds."
[ "$(echo "$st" | jq '.success')" = "true" ] || test_failed "Pod finalized the order transaction but marked it failed."

s=$(wait_status "$BOOK" "$ORDER_ID" "$DEADLINE" active) || test_failed "The test order did not rest in the book; its status is: $s."

CDEADLINE=$(aligned_deadline)
sent=$("$HERE/wallet.sh" send "$ORDERBOOK" "$CANCEL" "$BOOK" "$ORDER_ID" "$CDEADLINE" --nonce "$(( NONCE + 1 ))") \
  || test_failed "The order rests in the book, but the cancel could not be sent: $(echo "$sent" | jq -r '.error // "unknown error"'). It expires by itself in 5 minutes."
CANCEL_TX=$(echo "$sent" | jq -r '.tx')

st=$(wait_final "$CANCEL_TX") || test_failed "The cancel $CANCEL_TX was not finalized within 20 seconds. The order expires by itself in 5 minutes."
s=$(wait_status "$BOOK" "$ORDER_ID" "$CDEADLINE" canceled) || test_failed "The cancel was sent but the order's status is: $s. It expires by itself in 5 minutes."

result=$(jq -n --arg at "$(now_iso)" --arg m "$NAME" --arg o "$ORDER_TX" --arg c "$CANCEL_TX" --arg id "$ORDER_ID" \
  '{result: "passed", at: $at, market: $m, order_id: $id, order_tx: $o, cancel_tx: $c, error: null}')
echo "$result" | "$HERE/profile.sh" set-test >/dev/null
jq -n --argjson r "$result" '{ok: true} + $r + {meaning: "The wallet signed, pod accepted both transactions, the order rested in the book and was cancelled."}'
