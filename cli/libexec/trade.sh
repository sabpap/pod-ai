#!/usr/bin/env bash
# Place, change and cancel orders and stop-loss / take-profit triggers for the connected wallet, on
# pod staging. Every action is planned first (rounding, preview, plan id), then sent by its plan id,
# then followed to its outcome. Spec: specs/05-trading.md.
#
#: pod trade: place, change and cancel orders and stop-loss / take-profit triggers with the
#: connected wallet, on pod staging only.
#:
#: Every action goes through four steps: plan, approve, send, follow.
#:   1. Plan     pod trade ACTION ...          nothing is sent; prints plan_id, summary and preview
#:   2. Approve  while needs_approval is true (the approval setting is "ask", the default), show the
#:               person the summary and the preview and ask them to approve or deny. Only an approve
#:               sends; any other answer means deny. Never send a plan the person has not approved.
#:   3. Send     pod trade send PLAN_ID        sends exactly that plan; returns once pod accepts it.
#:               Tell the person at once: "Sent: ... · waiting for the next auction round". Accepted
#:               is not traded yet: pod trades at its next auction round.
#:   4. Follow   pod trade follow PLAN_ID      waits for the round and reports the outcome. Run it in
#:               the background if you can, so the conversation goes on; otherwise right after sending.
#:
#: Plan an action (nothing is sent):
#:   pod trade buy|sell MARKET SIZE --price P [--maker-only] [--ioc] [--reduce-only] [--rests 1h] [--spot]
#:   pod trade buy|sell MARKET SIZE --market [--max-price P | --min-price P | --band 1.5] [--reduce-only] [--spot]
#:   pod trade buy|sell MARKET --usd AMOUNT (--price P | --market)   size worked out from an amount of money
#:   pod trade close MARKET [--percent 50] [--price P | --band 1.5]
#:   pod trade edit ORDER_ID [--price P] [--size S]
#:   pod trade cancel ORDER_ID
#:   pod trade cancel-all [MARKET]
#:   pod trade stop-loss|take-profit MARKET --trigger-price P [--limit-price P | --band 1.5] [--size S] [--rests 30d]
#:   pod trade edit-trigger TRIGGER_ID [--trigger-price P] [--limit-price P] [--size S]
#:   pod trade cancel-trigger TRIGGER_ID
#: Then:
#:   pod trade send PLAN_ID                    sign and send exactly that plan
#:   pod trade follow PLAN_ID [--timeout 30]   wait for the auction round (seconds after it) and report
#: Any planning action with --send plans and sends in one call, only when the approval setting is "auto".
#:
#: Pick the action from the request:
#:   "buy 0.5 NVDA at 150"                     pod trade buy NVDA 0.5 --price 150
#:   "buy $10 of NVDA", "$10 of each"           pod trade buy NVDA --usd 10 --market
#:   "sell 0.5 NVDA at market"                 pod trade sell NVDA 0.5 --market
#:   "buy at market, but no more than 152"     pod trade buy NVDA 0.5 --market --max-price 152
#:   "short 2 AAPL at 230"                     pod trade sell AAPL 2 --price 230 (selling a perp you do
#:                                             not hold opens a short)
#:   "buy NVDAx spot"                          add --spot, or name the market "NVDA spot"
#:   "close my NVDA position", "close half"    pod trade close NVDA / pod trade close NVDA --percent 50
#:   "move that order to 149"                  pod trade edit ORDER_ID --price 149 (--size: the new total)
#:   "cancel that order", "cancel everything"  pod trade cancel ORDER_ID / pod trade cancel-all [MARKET]
#:   "stop-loss at 140", "take profit at 170"  pod trade stop-loss NVDA --trigger-price 140 /
#:                                             pod trade take-profit NVDA --trigger-price 170
#:   "move my stop to 145", "remove it"        pod trade edit-trigger TRIGGER_ID --trigger-price 145 /
#:                                             pod trade cancel-trigger TRIGGER_ID
#: Order ids come from pod account orders; trigger ids from pod account triggers (order_id there).
#: Markets are named loosely: NVDA, nvidia, "NVDA perp", "NVDA spot", or the 0x market id.
#:
#: A size is in units of the asset, not dollars. Prices differ a lot between markets (gold about
#: $3,500, NVDA about $150), so the same size in two markets can be very different amounts of money.
#: When the person names an amount of money, or asks for "a little" or "the same" of several markets,
#: use --usd AMOUNT instead of a size: a limit order is sized at its price, a market order at the
#: current price, rounded down to the market's size step. The plan's notes show the size it came to.
#:
#: Options:
#:   --price P          a limit order's price (with edit: the new price; with close: close at this
#:                      price instead of at market)
#:   --market           a market order: it trades at once, no worse than its worst price
#:   --max-price P      a market buy's worst price;  --min-price P: a market sell's worst price
#:   --band PCT         a market order's worst price as a percent from the current price, 0.1 to 20
#:                      (default: the market_band_pct setting, 2). For a trigger without --limit-price:
#:                      the band from the trigger price
#:   --usd AMOUNT       buy and sell: an amount of money instead of SIZE
#:   --maker-only       only rest in the book, never take (not with --ioc or --market)
#:   --ioc              immediate-or-cancel: fill what you can now, cancel the rest
#:   --reduce-only      perps: only shrink a position
#:   --rests TIME       how long a limit order stays, 1m to 30d (default: the default_ttl setting, 1d);
#:                      for a trigger, how long it stays armed (default 30d)
#:   --spot             pick the spot market when a name has both a perp and a spot market
#:   --percent N        close: the share of the position to close, above 0 up to 100 (default 100)
#:   --trigger-price P  stop-loss and take-profit: the price that fires it
#:   --limit-price P    a trigger's limit price; without it, it trades at market within the band
#:   --size S           a trigger's size (default: the whole position); with edit, the order's new
#:                      total size
#:   --send             plan and send in one call (approval "auto" only)
#:   --timeout S        follow: whole seconds to wait after the order's round (default 30)
#:
#: The plan's answer:
#:   plan_id          the id to send and follow. Plans expire after 2 minutes, because prices move
#:   summary          one line, e.g. "buy 0.5 NVDA perp at $150, rests 1 day"
#:   preview          market, side, type, size, price or worst_price, flags, order_value_usd, fee_usd,
#:                    margin_needed_usd and free_margin_after_usd (perps); cash_available_usd or
#:                    tokens_available (spot); value_at_current_price_usd (market orders: the value at
#:                    today's price; order_value_usd is the worst case)
#:   notes            what was changed or worked out: prices and sizes are rounded to the market's steps
#:                    on the side that never trades worse than asked (a buy price down, a sell price
#:                    up, a size down), a market order's worst price, a size worked out from --usd,
#:                    "not enough free margin". Give the person every note
#:   needs_approval   true while the approval setting is "ask"
#:   next             the command to run next
#: How to ask: "Approve: buy 0.5 NVDA perp at $150 (rests 1 day)? Value $75, fee up to $0.03, margin
#: $3.75, free margin after $96.2." For a market order give value_at_current_price_usd and say the
#: worst case is order_value_usd. Add each note.
#:
#: Send's answer: sent, summary ("Sent: ... · waiting for the next auction round"), txs, ids (the
#: order or trigger ids). In a terminal with approval "ask", pod trade send shows the plan and asks
#: "Send it? [y/N]" itself; a no exits with code 3 and sends nothing.
#:
#: Follow's answer: final, outcome. Report the outcome in one line: "Filled: ... at an average $...,
#: fee $...", "Partly filled ...", "Resting in the book ...", "Refused: not enough margin ...",
#: "Armed: stop-loss ...", "Cancelled.". final: false means nothing settled within the timeout: say
#: so, and offer to check again with pod trade follow PLAN_ID or pod account orders.
#:
#: Rules pod applies:
#:   Only the connected wallet trades, only on pod staging (the chain id is checked before every send).
#:   Pod refuses maker-only with immediate-or-cancel, maker-only on a market order, and reduce-only on
#:   spot; pod trade refuses them first, with a plain message.
#:   A stop-loss must sit on the losing side of the current price and a take-profit on the winning side.
#:   cancel-all covers orders, not triggers.
#:   Pod's refusals are passed on with pod's own reason. A refusal for a lasting reason (region block,
#:   blacklist, frozen account) also makes pod status report a problem.
#:   The settings approval, market_band_pct and default_ttl are shown and changed with pod settings,
#:   only when the person asks.
#:
#: Not part of pod: advice, strategies, risk limits, bracket orders, free-form batches, transfers,
#: withdrawals and bot keys.

source "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"

PLANS="$POD_HOME/plans"
PLAN_LIFE_S=120                 # a plan expires after 2 minutes: prices move
LAG_US=5000000                  # deadline 5 s ahead, on the 500 ms auction grid
TRIGGER_TTL_DEFAULT="30d"       # triggers protect positions that are often held longer than a day
USD_TOKEN="0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
SUBMIT_TRIGGER="submitTrigger(bytes32,int256,uint256,uint256,uint8,uint8,uint128,uint128,bool,bool)"
UPDATE="update(bytes32,bytes32,uint256,uint256,address,uint128)"
UPDATE_TRIGGER="updateTrigger(bytes32,bytes32,int256,uint256,uint256,uint128)"
CANCEL_TRIGGER="cancelTrigger(bytes32,bytes32,uint128)"
SUBMIT_BATCH="submitBatch(bytes[])"
TAKE_PROFIT=0; STOP_LOSS=1; GROUP_ASSET=1   # checked on staging 2026-11-26
FLAG_REDUCE_ONLY=1; FLAG_IOC=2

T=$(mktemp -d "${TMPDIR:-/tmp}/pod-trade.XXXXXX")
trap 'rm -rf "$T"' EXIT

# --- helpers ------------------------------------------------------------------------------------------------

get() {   # get PATH FILE: a REST route into FILE; fails with pod's own reason
  local code why route="${1%%\?*}"
  code=$(curl -sS --max-time 20 --retry 1 --retry-delay 1 -o "$2" -w '%{http_code}' "$POD_REST$1" 2>/dev/null) || code=000
  [ "$code" = 200 ] && return 0
  [ "$code" = 000 ] && fail trade "Pod did not answer $route in time." "Try again in a moment."
  why=$(head -c 200 "$2" 2>/dev/null | tr -d '\n' || true)
  fail trade "Pod answered $route with an error ($code${why:+: $why})." "This is on pod's side. Try again in a moment."
}

need_wallet() {
  profile_exists || fail trade "No wallet is connected." "Connect one with pod setup."
  ADDR=$(profile_get '.wallet.address')
}

pj() { jq -L "$HERE" "$@"; }   # jq with pod.jq available

load_market() {   # load_market QUERY SPOT(true|false): sets MKT (json) and its fields
  get /clob/markets "$T/markets"
  MKT=$(pj --arg q "$1" --argjson s "$2" 'include "pod"; find_market($q; $s)' "$T/markets")
  [ "$MKT" != "null" ] || fail trade "No market called '$1'." "Name it by its ticker (e.g. NVDA), add 'spot' for the spot market, or give its 0x market id."
  [ "$(echo "$MKT" | jq -r .status)" = active ] || fail trade "$(echo "$MKT" | jq -r '.base_token_symbol + " " + .market_type') is $(echo "$MKT" | jq -r .status), not open for trading."
  BOOK=$(echo "$MKT" | jq -r .id)
  MTYPE=$(echo "$MKT" | jq -r .market_type)
  MNAME=$(echo "$MKT" | jq -r '.base_token_symbol + " " + .market_type')
  TICK=$(to_dec "$(echo "$MKT" | jq -r .tick_precision)")
  LOT=$(to_dec "$(echo "$MKT" | jq -r .lot_size)")
  MIN_NOTIONAL=$(to_dec "$(echo "$MKT" | jq -r '.min_notional // "0"')")
  MAKER_FEE=$(to_wei "$(echo "$MKT" | jq -r .maker_fee)")
  TAKER_FEE=$(to_wei "$(echo "$MKT" | jq -r .taker_fee)")
  IM=$(to_dec "$(echo "$MKT" | jq -r '.initial_margin // "0"')")
}

market_by_id() {   # market_by_id BOOK: like load_market, from an order's market id
  load_market "$1" false
}

# The market's current price in wei: the mark price for perps, the last price for spot. Pod sends 0
# for a price it does not have (e.g. a halted market), which counts as none.
REF_JQ='.markets[] | select(.orderbook_id == $id) | [.mark_price, .last_clearing_price]
  | map(select(. != null and . != "0" and . != "0x0")) | .[0] // empty'

# ref_price VAR: set VAR to the current price, or fail. It sets a variable rather than printing, so it
# never runs inside $(...), where its failure message would be captured and lost.
ref_price() {
  get /clob/markets/stats "$T/stats"
  local _p
  _p=$(jq -r --arg id "$BOOK" "$REF_JQ" "$T/stats")
  [ -n "$_p" ] || fail trade "$MNAME has no current price to work from." "Give an explicit price."
  printf -v "$1" '%s' "$(to_dec "$_p")"
}

# ref_maybe VAR: like ref_price, but leaves VAR empty instead of failing. For optional preview fields.
ref_maybe() {
  local _p=""
  _p=$(curl -sS --fail --max-time 10 "$POD_REST/clob/markets/stats" 2>/dev/null | jq -r --arg id "$BOOK" "$REF_JQ" 2>/dev/null) || _p=""
  if [ -n "$_p" ]; then printf -v "$1" '%s' "$(to_dec "$_p")"; else printf -v "$1" '%s' ""; fi
}

# num_wei VAR VALUE WHAT: set VAR to a user's decimal as wei, or fail. It sets a variable rather than
# printing, so it never runs inside $(...), where a failure message would be captured and lost.
num_wei() {
  local _w
  _w=$(to_wei "$2") || fail trade "$3 '$2' is not a plain positive number (digits and at most one point, up to 18 decimals)."
  printf -v "$1" '%s' "$_w"
}

floor_to() { bc_int "$1 / $2 * $2"; }
ceil_to()  { bc_int "($1 + $2 - 1) / $2 * $2"; }
round_price() {   # round_price WEI SIDE: buy down, sell up (never trades worse than asked)
  if [ "$2" = buy ]; then floor_to "$1" "$TICK"; else ceil_to "$1" "$TICK"; fi
}
band_price() {   # band_price REF_WEI SIDE BAND_PCT: worst price, ref ± band, rounded inward
  local bp; bp=$(bc_int "$3 * 100 / 1")
  if [ "$2" = buy ]; then floor_to "$(bc_int "$1 * (10000 + $bp) / 10000")" "$TICK"
  else ceil_to "$(bc_int "$1 * (10000 - $bp) / 10000")" "$TICK"; fi
}
check_band() {
  echo "$1" | grep -Eq '^[0-9]+(\.[0-9]{1,2})?$' && [ "$(echo "$1 >= 0.1 && $1 <= 20" | bc)" = 1 ] \
    || fail trade "The band must be a number from 0.1 to 20 (percent), at most 2 decimals."
}

NOTES="[]"
note() { NOTES=$(echo "$NOTES" | jq --arg n "$1" '. + [$n]'); }

account_numbers() {   # sets ACCT_VALUE, MARGIN_USED (wei) and saves positions to $T/positions
  get "/clob/positions/$ADDR" "$T/positions"
  ACCT_VALUE=$(to_dec "$(jq -r .account_value "$T/positions")")
  MARGIN_USED=0
  for m in $(jq -r '.positions[].margin' "$T/positions"); do MARGIN_USED=$(bc_int "$MARGIN_USED + $(to_dec "$m")"); done
}

position_of() {   # position_of BOOK: the signed position size in wei, or empty
  jq -r --arg id "$1" '.positions[] | select(.orderbook_id == $id) | .size' "$T/positions" | head -1
}

duration_text() {   # 86400 -> "1 day"
  local s="$1"
  if [ $(( s % 86400 )) -eq 0 ]; then echo "$(( s / 86400 )) day$([ $(( s / 86400 )) = 1 ] || echo s)"
  elif [ $(( s % 3600 )) -eq 0 ]; then echo "$(( s / 3600 )) hour$([ $(( s / 3600 )) = 1 ] || echo s)"
  elif [ $(( s % 60 )) -eq 0 ]; then echo "$(( s / 60 )) minute$([ $(( s / 60 )) = 1 ] || echo s)"
  else echo "$s seconds"; fi
}

rest_us() {   # rest_us VAR WHEN DEFAULT: set VAR to the resting time in microseconds, or fail
  local _s; _s=$(duration_s "${2:-$3}") || fail trade "'${2:-$3}' is not a time such as 10m, 1h or 7d."
  { [ "$_s" -ge 60 ] && [ "$_s" -le 2592000 ]; } || fail trade "Resting time must be between 1m and 30d."
  printf -v "$1" '%s' $(( _s * 1000000 ))
}

usd() { local v; v=$(human "$1"); case "$v" in -*) echo "-\$${v#-}" ;; *) echo "\$$v" ;; esac; }

find_open_order() {   # find_open_order ORDER_ID: the open (pending or active) order as JSON, or fail
  local id st cursor
  id=$(echo "$1" | tr 'A-F' 'a-f')
  for st in active pending; do
    cursor=""
    while :; do
      get "/clob/orders/$ADDR?status=$st&limit=500${cursor:+&cursor=$cursor}" "$T/o"
      ORDER=$(jq -c --arg id "$id" '.orders[] | select((.order_id | ascii_downcase) == $id)' "$T/o" | head -1)
      [ -n "$ORDER" ] && return 0
      cursor=$(jq -r '.next_cursor // empty' "$T/o"); [ -z "$cursor" ] && break
    done
  done
  fail trade "No open order $1 on this account." "List open orders with pod account orders."
}

find_trigger() {   # find_trigger TRIGGER_ID: the armed trigger as JSON, or fail
  local id cursor=""
  id=$(echo "$1" | tr 'A-F' 'a-f')
  while :; do
    get "/clob/triggers/$ADDR?limit=200${cursor:+&cursor=$cursor}" "$T/t"
    TRIG=$(jq -c --arg id "$id" '.triggers[] | select((.order_id | ascii_downcase) == $id)' "$T/t" | head -1)
    [ -n "$TRIG" ] && return 0
    cursor=$(jq -r '.next_cursor // empty' "$T/t"); [ -z "$cursor" ] && break
  done
  fail trade "No armed trigger $1 on this account." "List triggers with pod account triggers."
}

# --- plans ------------------------------------------------------------------------------------------------

save_plan() {   # save_plan JSON: writes the plan and prints the answer
  mkdir -p "$PLANS"; chmod 700 "$PLANS"
  find "$PLANS" -name 'p*.json' -mmin +60 -delete 2>/dev/null || true
  local id now exp approval
  id="p$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
  now=$(date +%s); exp=$(( now + PLAN_LIFE_S ))
  approval=$(setting approval)
  echo "$1" | jq --arg id "$id" --arg a "$ADDR" --argjson exp "$exp" --arg at "$(now_iso)" --argjson notes "$NOTES" \
    '. + {plan_id: $id, account: $a, created_at: $at, expires: $exp, notes: $notes, state: "planned"}' \
    > "$PLANS/$id.json"
  chmod 600 "$PLANS/$id.json"
  PLAN_ID="$id"
  if $SEND; then
    # With approval "ask", one-step sending works only for a person at a terminal, who is asked below.
    [ "$approval" = auto ] || on_tty || fail trade "Approval is set to 'ask', so the plan $id was saved but not sent." "Show the person the preview, ask them, and only on approve run: pod trade send $id"
    do_send "$id"; return
  fi
  jq --arg ap "$approval" --arg exp_iso "$(date -u -r "$exp" +%Y-%m-%dT%H:%M:%SZ)" '
    {ok: true, plan_id, action, summary, preview, notes, approval: $ap, needs_approval: ($ap == "ask"),
     expires_at: $exp_iso,
     next: (if $ap == "ask" then "Show the person the summary and preview, ask them to approve or deny, and only on approve run: pod trade send \(.plan_id)"
            else "Run: pod trade send \(.plan_id)" end)}' "$PLANS/$id.json"
}

load_plan() {   # load_plan ID: checks it and sets PF
  echo "$1" | grep -Eq '^p[0-9a-f]{8}$' || fail trade "'$1' is not a plan id."
  PF="$PLANS/$1.json"
  [ -f "$PF" ] || fail trade "No plan $1." "Plans expire; make a new one."
}

# --- sending ------------------------------------------------------------------------------------------------

on_tty() { [ -t 0 ] && [ -t 1 ]; }

# confirm_on_tty PLAN_ID: a person running pod in a terminal, with approval "ask", is shown the plan
# and asked here. Anything but yes sends nothing and exits 3. Without a terminal (an agent) nothing is
# asked here: the agent asks, and in Claude Code the pod plugin's hook makes Claude Code ask.
confirm_on_tty() {
  { [ "$(setting approval)" = ask ] && on_tty; } || return 0
  local ans=""
  {
    echo
    echo "  $(jq -r .summary "$PF")"
    jq -r '.preview | to_entries[] | "    \(.key): \(.value | if type == "array" then join(", ") else tostring end)"' "$PF"
    jq -r '.notes[] | "    note: \(.)"' "$PF"
    printf '  Send it? [y/N] '
  } > /dev/tty
  read -r ans < /dev/tty || ans=""
  case "$ans" in y|Y|yes|Yes|YES) return 0 ;; esac
  jq -n --arg id "$1" '{ok: false, step: "approval", plan_id: $id, error: "Not sent: the plan was not approved.",
    fix: "Make a new plan when you want to trade, or answer y within 2 minutes: pod trade send \($id)"}'
  exit 3
}

wait_accepted() {   # wait_accepted TX: until pod finalizes it; prints success true/false, or fails
  local i st
  for i in $(seq 1 40); do
    st=$(rpc_result pod_getTxStatus "[\"$1\"]" 2>/dev/null || echo '{}')
    if [ "$(echo "$st" | jq -r '.status // empty')" = finalized ]; then echo "$st" | jq -r '.success'; return 0; fi
    sleep 0.25
  done
  return 1
}

oid() { cast keccak "$(cast abi-encode 'f(address,uint64,uint32)' "$ADDR" "$1" "$2")"; }

do_send() {   # do_send PLAN_ID
  load_plan "$1"
  need_wallet
  [ "$(jq -r .state "$PF")" = planned ] || fail trade "Plan $1 was already sent." "Follow it with: pod trade follow $1"
  [ "$(jq -r .expires "$PF")" -ge "$(date +%s)" ] || fail trade "Plan $1 has expired (plans last 2 minutes, because prices move)." "Make the plan again."
  [ "$(jq -r .account "$PF" | tr 'A-F' 'a-f')" = "$(echo "$ADDR" | tr 'A-F' 'a-f')" ] || fail trade "Plan $1 was made for another wallet." "Make the plan again."
  confirm_on_tty "$1"

  local nonce t dl kind book txs="[]" ids="[]" i n out tx ok
  # A failed lookup must stop here: inside printf's argument it would quietly become nonce 0.
  nonce=$(rpc_result eth_getTransactionCount "[\"$ADDR\",\"pending\"]" 2>/dev/null | jq -r .) \
    || fail trade "Pod did not answer the request for this account's next transaction number. Nothing was sent." "Try again in a moment: pod trade send $1"
  nonce=$(printf '%d' "$nonce")
  t=$(( $(now_us) + LAG_US )); dl=$(( (t + AUCTION_US - 1) / AUCTION_US * AUCTION_US ))
  kind=$(jq -r .kind "$PF"); book=$(jq -r '.call.book // empty' "$PF")

  # Each line of $T/txs is one transaction: a function signature, then its arguments, tab-separated.
  : > "$T/txs"
  case "$kind" in
    order)
      jq -r --arg dl "$dl" '.call | [env.SUBMIT_ORDER_SIG, .book, .size, .price, (.order_type | tostring), $dl,
        ((($dl | tonumber) + .rest_us) | tostring), (.flags | tostring)] | @tsv' "$PF" > "$T/txs"
      ids=$(jq -n --arg id "$(oid "$nonce" 0)" '[$id]') ;;
    edit)
      jq -r --arg dl "$dl" --arg tok "$USD_TOKEN" '.call | [env.UPDATE_SIG, .book, .order_id, .size, .price, $tok, $dl] | @tsv' "$PF" > "$T/txs"
      ids=$(jq '[.call.order_id]' "$PF") ;;
    cancel)
      jq -r --arg dl "$dl" '.call | ["cancel(bytes32,bytes32,uint128)", .book, .order_id, $dl] | @tsv' "$PF" > "$T/txs"
      ids=$(jq '[.call.order_id]' "$PF") ;;
    trigger)
      jq -r --arg dl "$dl" '.call | [env.SUBMIT_TRIGGER_SIG, .book, .size, .limit_price, .trigger_price,
        (.trigger_type | tostring), (.grouping | tostring), $dl, ((($dl | tonumber) + .rest_us) | tostring),
        (.reduce_only | tostring), (.ioc | tostring)] | @tsv' "$PF" > "$T/txs"
      ids=$(jq -n --arg id "$(oid "$nonce" 0)" '[$id]') ;;
    edit-trigger)
      jq -r --arg dl "$dl" '.call | [env.UPDATE_TRIGGER_SIG, .book, .trigger_id, .size, .limit_price, .trigger_price, $dl] | @tsv' "$PF" > "$T/txs"
      ids=$(jq '[.call.trigger_id]' "$PF") ;;
    cancel-trigger)
      jq -r --arg dl "$dl" '.call | [env.CANCEL_TRIGGER_SIG, .book, .trigger_id, $dl] | @tsv' "$PF" > "$T/txs"
      ids=$(jq '[.call.trigger_id]' "$PF") ;;
    cancel-all)
      # up to 64 cancels per batch transaction
      n=$(jq '.call.orders | length' "$PF"); i=0
      while [ "$i" -lt "$n" ]; do
        inner=""
        for row in $(jq -r --argjson s "$i" '.call.orders[$s:$s + 64][] | "\(.book),\(.order_id)"' "$PF"); do
          c=$(cast calldata "cancel(bytes32,bytes32,uint128)" "${row%%,*}" "${row#*,}" "$dl")
          inner="${inner:+$inner,}$c"
        done
        printf '%s\t%s\n' "$SUBMIT_BATCH" "[$inner]" >> "$T/txs"
        i=$(( i + 64 ))
      done
      ids=$(jq '[.call.orders[].order_id]' "$PF") ;;
    *) fail trade "Plan $1 has an unknown kind '$kind'." ;;
  esac

  n=0
  while IFS="$(printf '\t')" read -r -a parts; do
    out=$("$HERE/wallet.sh" send "$ORDERBOOK" "${parts[@]}" --nonce "$(( nonce + n ))") || {
      jq --argjson txs "$txs" --arg err "$(echo "$out" | jq -r '.error // "send failed"')" \
        '.state = (if ($txs | length) > 0 then "partly sent" else "failed" end) | .sent = {txs: $txs} | .error = $err' "$PF" > "$PF.new" && mv "$PF.new" "$PF"
      echo "$out" | jq --argjson txs "$txs" '. + {sent_before_failure: $txs}'
      exit 1
    }
    tx=$(echo "$out" | jq -r .tx)
    ok=$(wait_accepted "$tx") || ok=unknown
    if [ "$ok" = false ]; then
      jq --arg tx "$tx" '.state = "refused" | .sent = {txs: [$tx]}' "$PF" > "$PF.new" && mv "$PF.new" "$PF"
      fail trade "Pod accepted transaction $tx but marked it failed." "Check the account with pod account activity."
    fi
    txs=$(echo "$txs" | jq --arg tx "$tx" '. + [$tx]')
    n=$(( n + 1 ))
  done < "$T/txs"

  jq --argjson txs "$txs" --argjson ids "$ids" --argjson nonce "$nonce" --argjson dl "$dl" --arg at "$(now_iso)" \
    '.state = "sent" | .sent = {at: $at, nonce: $nonce, deadline_us: $dl, txs: $txs, ids: $ids}' "$PF" > "$PF.new" && mv "$PF.new" "$PF"
  jq '{ok: true, plan_id, action, sent: true,
       summary: ("Sent: " + .summary + " · waiting for the next auction round"),
       txs: .sent.txs, ids: .sent.ids,
       next: "Run in the background: pod trade follow \(.plan_id). Report its outcome when it ends."}' "$PF"
}
export SUBMIT_ORDER_SIG="$SUBMIT_ORDER" UPDATE_SIG="$UPDATE" SUBMIT_TRIGGER_SIG="$SUBMIT_TRIGGER" \
       UPDATE_TRIGGER_SIG="$UPDATE_TRIGGER" CANCEL_TRIGGER_SIG="$CANCEL_TRIGGER"

# --- following ------------------------------------------------------------------------------------------------

# These two run inside $(...) while following an order, so they must not stop the script: a passing
# REST error counts as "not known yet" and the follow loop asks again.
order_state() {   # order_state BOOK ID: the order as JSON, or empty
  curl -sS --fail --max-time 15 -o "$T/os" "$POD_REST/clob/orders/$ADDR?orderbook=$1&limit=100" 2>/dev/null || return 0
  jq -c --arg id "$(echo "$2" | tr 'A-F' 'a-f')" '.orders[] | select((.order_id | ascii_downcase) == $id)' "$T/os" | head -1
}

activity_reject() {   # activity_reject ID: a modify_reject or cancel_reject reason for the id, or empty
  curl -sS --fail --max-time 15 -o "$T/ar" "$POD_REST/clob/activity/$ADDR?limit=100&activity_types=modify_reject,cancel_reject" 2>/dev/null || return 0
  jq -r --arg id "$(echo "$1" | tr 'A-F' 'a-f')" '[.activity // {} | to_entries[] | .value[] | select((.id | ascii_downcase) == $id) | .why][0] // empty' "$T/ar"
}

describe_order() {   # describe_order ORDER_JSON MARKET_NAME: one plain sentence about where the order stands
  echo "$1" | pj -r --arg m "$2" 'include "pod";
    def usd: if startswith("-") then "-$" + .[1:] else "$" + . end;
    (.filled_base_amount | amount) as $f | (.initial_size | amount | abs_str) as $s
    | (.effective_price | price_or_null) as $avg | (.fee | amount) as $fee
    | if .status == "filled" then "Filled: \(.side) \($s) \($m) at an average \($avg | usd), fee \($fee | usd)."
      elif .status == "active" and $f != "0" then "Partly filled: \($f) of \($s) at an average \($avg | usd); the rest rests in the book until \(.end | us_time // "cancelled")."
      elif .status == "active" then "Resting in the book: \(.side) \($s) \($m) at \(.price | amount | usd), until \(.end | us_time // "cancelled")."
      elif .status == "margin_canceled" then "Refused: not enough margin for this order."
      elif .status == "post_only_refused" then "Refused: it would have traded at once, and it was maker-only."
      elif .status == "self_trade_canceled" then "Cancelled by pod: it would have traded with your own order."
      elif .status == "invalid" then "Refused: \(.invalid_reason // "pod rejected it")."
      elif (.status == "expired" or .status == "canceled") and $f != "0" then "Partly filled: \($f) of \($s) at an average \($avg | usd); the rest was \(.status)."
      elif .status == "expired" then "Not filled: nothing was available at your price or better before it expired."
      elif .status == "canceled" then "Cancelled."
      else "Status: \(.status)." end'
}

do_follow() {   # do_follow PLAN_ID TIMEOUT_S
  load_plan "$1"; need_wallet
  case "$(jq -r .state "$PF")" in
    sent|done) ;;
    *) fail trade "Plan $1 has not been sent (state: $(jq -r .state "$PF"))." ;;
  esac
  local kind book dl until_us id o msg final=false st why name
  kind=$(jq -r .kind "$PF"); book=$(jq -r '.call.book // empty' "$PF"); name=$(jq -r '.market_name // ""' "$PF")
  dl=$(jq -r .sent.deadline_us "$PF"); until_us=$(( dl + $2 * 1000000 ))
  id=$(jq -r '.sent.ids[0]' "$PF")
  msg=""
  while :; do
    case "$kind" in
      order)
        o=$(order_state "$book" "$id")
        if [ -n "$o" ]; then
          st=$(echo "$o" | jq -r .status); msg=$(describe_order "$o" "$name")
          # a resting order is an outcome once its round has passed; pending is not
          { [ "$st" != pending ] && { [ "$st" != active ] || [ "$(now_us)" -gt "$(( dl + 1500000 ))" ]; }; } && final=true
        fi ;;
      cancel|edit)
        o=$(order_state "$book" "$id")
        if [ -n "$o" ]; then
          st=$(echo "$o" | jq -r .status)
          if [ "$kind" = cancel ]; then
            case "$st" in
              canceled) msg="Cancelled."; final=true ;;
              filled) msg="Too late: the order had already filled. $(describe_order "$o" "$name")"; final=true ;;
              active|pending) ;;
              *) msg="$(describe_order "$o" "$name")"; final=true ;;
            esac
          else
            if [ "$(echo "$o" | jq -r '.price | ascii_downcase')" = "$(jq -r .call.price_hex "$PF")" ] \
               && [ "$(echo "$o" | jq -r '.initial_size | ltrimstr("-")')" = "$(jq -r .call.size "$PF")" ]; then
              msg="Changed: $(describe_order "$o" "$name")"; final=true
            elif [ "$st" != active ] && [ "$st" != pending ]; then msg="Not changed: $(describe_order "$o" "$name")"; final=true
            fi
          fi
        fi
        if ! $final && [ "$(now_us)" -gt "$(( dl + 3000000 ))" ]; then
          why=$(activity_reject "$id"); [ -n "$why" ] && { msg="Refused by pod: $why."; final=true; }
        fi ;;
      cancel-all)
        get "/clob/orders/$ADDR?status=active&limit=500" "$T/oa"
        left=$(jq --argjson ids "$(jq '[.sent.ids[] | ascii_downcase]' "$PF")" '[.orders[] | select((.order_id | ascii_downcase) as $i | $ids | index($i))] | length' "$T/oa")
        total=$(jq '.sent.ids | length' "$PF")
        if [ "$left" = 0 ] && [ "$(now_us)" -gt "$dl" ]; then msg="$([ "$total" = 1 ] && echo "Cancelled 1 order." || echo "Cancelled all $total orders.")"; final=true
        else msg="$(( total - left )) of $total cancelled so far."; fi ;;
      trigger|edit-trigger|cancel-trigger)
        get "/clob/triggers/$ADDR?limit=200" "$T/tr"
        o=$(jq -c --arg id "$(echo "$id" | tr 'A-F' 'a-f')" '.triggers[] | select((.order_id | ascii_downcase) == $id)' "$T/tr" | head -1)
        if [ "$kind" = cancel-trigger ]; then
          [ -z "$o" ] && [ "$(now_us)" -gt "$dl" ] && { msg="Trigger removed."; final=true; }
        elif [ -n "$o" ]; then
          verb=$(jq -r '.call.side // empty | if . == "buy" then "buys" else "sells" end' "$PF"); verb="${verb:-sells or buys}"
          desc=$(echo "$o" | pj -r --arg m "$name" --arg verb "$verb" 'include "pod";
            "\(.trigger_type | sub("_"; "-")) on \($m): fires at $\(.trigger_price | amount), then \(if .ioc then "\($verb) at market, no worse than" else "\($verb) with a limit order at" end) $\(.limit_price | amount); size \(if (.size | int_str) == "0" then "the whole position" else (.size | amount | abs_str) end)"')
          if [ "$kind" = trigger ]; then msg="Armed: $desc."; final=true
          elif [ "$(echo "$o" | jq -r '.trigger_price | ascii_downcase')" = "$(jq -r .call.trigger_price_hex "$PF")" ]; then msg="Changed: $desc."; final=true
          fi
        fi ;;
    esac
    $final && break
    if [ "$(now_us)" -gt "$until_us" ]; then
      [ -z "$msg" ] && msg="No outcome yet: pod has not settled it within $2 seconds after its round."
      jq -n --arg id "$1" --arg m "$msg" '{ok: true, plan_id: $id, final: false, outcome: $m,
        next: "Check again with pod trade follow \($id), or look at pod account orders."}'
      return 0
    fi
    sleep 1
  done
  jq --arg m "$msg" '.state = "done" | .outcome = $m' "$PF" > "$PF.new" && mv "$PF.new" "$PF"
  jq '{ok: true, plan_id, action, final: true, outcome, txs: .sent.txs, ids: .sent.ids}' "$PF"
}

# --- arguments ------------------------------------------------------------------------------------------------

ACTION="${1:-}"; shift || true
POS=(); PRICE=""; SIZE_OPT=""; MARKET_ORDER=false; MAX_PRICE=""; MIN_PRICE=""; BAND=""; MAKER=false; IOC=false
REDUCE=false; RESTS=""; SPOT=false; PERCENT=""; TRIG_PRICE=""; LIMIT_PRICE=""; SEND=false; TIMEOUT=30; USD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --price) PRICE="${2:-}"; shift 2 ;;
    --size) SIZE_OPT="${2:-}"; shift 2 ;;
    --usd) USD="${2:-}"; shift 2 ;;
    --market) MARKET_ORDER=true; shift ;;
    --max-price) MAX_PRICE="${2:-}"; shift 2 ;;
    --min-price) MIN_PRICE="${2:-}"; shift 2 ;;
    --band) BAND="${2:-}"; shift 2 ;;
    --maker-only) MAKER=true; shift ;;
    --ioc) IOC=true; shift ;;
    --reduce-only) REDUCE=true; shift ;;
    --rests) RESTS="${2:-}"; shift 2 ;;
    --spot) SPOT=true; shift ;;
    --percent) PERCENT="${2:-}"; shift 2 ;;
    --trigger-price) TRIG_PRICE="${2:-}"; shift 2 ;;
    --limit-price) LIMIT_PRICE="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    --send) SEND=true; shift ;;
    -*) fail_usage trade "Unknown option $1." "See pod trade --help." ;;
    *) POS+=("$1"); shift ;;
  esac
done
arg() { echo "${POS[$1]:-}"; }

# --- actions ------------------------------------------------------------------------------------------------

plan_order() {   # buy | sell
  local side="$1" q size_in size p_in price worst flags=0 otype=0 rest val fee rate margin free summary ref="" band
  q=$(arg 0); size_in=$(arg 1)
  [ -n "$q" ] || fail trade "Usage: pod trade $side MARKET SIZE --price P, or --market; --usd AMOUNT instead of SIZE for an amount of money."
  if [ -n "$USD" ]; then
    [ -z "$size_in" ] || fail trade "Give either a SIZE in units or --usd for an amount of money, not both."
  else
    [ -n "$size_in" ] || fail trade "Usage: pod trade $side MARKET SIZE --price P, or --market; --usd AMOUNT instead of SIZE for an amount of money."
  fi
  need_wallet; load_market "$q" "$SPOT"

  if $MARKET_ORDER; then
    [ -z "$PRICE" ] || fail trade "Give either --price (limit order) or --market, not both."
    $MAKER && fail trade "A market order cannot be maker-only: it trades at once by design."
    otype=1; IOC=true
    if [ -n "$MAX_PRICE$MIN_PRICE" ]; then
      [ "$side" = buy ] && [ -n "$MIN_PRICE" ] && fail trade "A buy takes --max-price, not --min-price."
      [ "$side" = sell ] && [ -n "$MAX_PRICE" ] && fail trade "A sell takes --min-price, not --max-price."
      p_in="$MAX_PRICE$MIN_PRICE"; num_wei worst "$p_in" "Price"
      price=$(round_price "$worst" "$side")
      [ "$price" != "$worst" ] && note "worst price $p_in → $(human "$price") (rounded to the market's step, never worse than asked)"
    else
      band="${BAND:-$(setting market_band_pct)}"; check_band "$band"
      ref_price ref
      price=$(band_price "$ref" "$side" "$band")
      note "worst price $(usd "$price"): the current price $(usd "$ref") $([ "$side" = buy ] && echo plus || echo minus) $band%"
    fi
  else
    [ -n "$PRICE" ] || fail trade "A limit order needs --price; use --market to trade at the current price."
    [ -z "$MAX_PRICE$MIN_PRICE$BAND" ] || fail trade "--max-price, --min-price and --band are for market orders."
    num_wei p_in "$PRICE" "Price"
    price=$(round_price "$p_in" "$side")
    [ "$price" != "$p_in" ] && note "price $PRICE → $(human "$price") (rounded $([ "$side" = buy ] && echo down || echo up) to the market's step of $(human "$TICK"), so it never trades worse than asked)"
    [ "$(bc_int "$price > 0")" = 1 ] || fail trade "Price $PRICE rounds to zero."
  fi

  # The size: in units as given, or worked out from an amount of money. A limit order is sized at its
  # price; a market order at the current price, since its worst price is only a cap.
  if [ -n "$USD" ]; then
    local usd_wei basis
    num_wei usd_wei "$USD" "Amount"
    if [ "$otype" = 1 ]; then [ -n "$ref" ] || ref_price ref; basis=$ref; else basis=$price; fi
    size=$(floor_to "$(bc_int "$usd_wei * 10^18 / $basis")" "$LOT")
    [ "$(bc_int "$size > 0")" = 1 ] || fail trade "\$$USD buys less than $MNAME's smallest step ($(human "$LOT") at $(usd "$basis"))."
    note "size $(human "$size") = \$$USD at $(usd "$basis")$([ "$otype" = 1 ] && echo " (the current price)"), rounded down to the market's step of $(human "$LOT")"
  else
    num_wei size "$size_in" "Size"
    local rsize; rsize=$(floor_to "$size" "$LOT")
    [ "$rsize" != "$size" ] && note "size $size_in → $(human "$rsize") (rounded down to the market's step of $(human "$LOT"))"
    [ "$(bc_int "$rsize > 0")" = 1 ] || fail trade "Size $size_in is smaller than $MNAME's smallest step ($(human "$LOT"))."
    size=$rsize
  fi
  $MAKER && $IOC && fail trade "Pod refuses maker-only together with immediate-or-cancel."
  $REDUCE && [ "$MTYPE" != perp ] && fail trade "Reduce-only exists on perp markets only."
  $REDUCE && flags=$(( flags | FLAG_REDUCE_ONLY )); $IOC && flags=$(( flags | FLAG_IOC )); $MAKER && flags=$(( flags | FLAG_POST_ONLY ))
  rest_us rest "$RESTS" "$(setting default_ttl)"

  val=$(bc_int "$size * $price / 10^18")
  [ "$(bc_int "$MIN_NOTIONAL > 0 && $val < $MIN_NOTIONAL")" = 1 ] && fail trade "The order is worth $(usd "$val"); $MNAME's minimum is $(usd "$MIN_NOTIONAL")."
  if $MAKER; then rate=$MAKER_FEE; else rate=$TAKER_FEE; fi
  fee=$(bc_int "$val * $rate / 10^18")
  account_numbers
  local signed; [ "$side" = buy ] && signed="$size" || signed="-$size"
  local preview
  if [ "$MTYPE" = perp ] && ! $REDUCE; then
    margin=$(bc_int "$val * $IM / 10^18"); free=$(bc_int "$ACCT_VALUE - $MARGIN_USED - $margin")
    preview=$(jq -n --arg v "$(human "$val")" --arg f "$(human "$fee")" --arg m "$(human "$margin")" --arg fr "$(human "$free")" \
      '{order_value_usd: $v, fee_usd: $f, margin_needed_usd: $m, free_margin_after_usd: $fr}')
    [ "$(bc_int "$free < 0")" = 1 ] && note "not enough free margin: pod will refuse this order"
  elif [ "$MTYPE" = perp ]; then
    preview=$(jq -n --arg v "$(human "$val")" --arg f "$(human "$fee")" '{order_value_usd: $v, fee_usd: $f, margin_needed_usd: "0 (reduce-only: it can only shrink the position)"}')
  else
    get "/clob/balances/$ADDR" "$T/bal"
    if [ "$side" = buy ]; then
      preview=$(jq -n --arg v "$(human "$val")" --arg f "$(human "$fee")" --arg c "$(human "$(to_dec "$(jq -r .cash "$T/bal")")")" \
        '{order_value_usd: $v, fee_usd: $f, cash_available_usd: $c}')
    else
      local held; held=$(jq -r --arg id "$BOOK" '[.balances[] | select(.orderbook_id == $id) | .free_balance][0] // "0x0"' "$T/bal")
      preview=$(jq -n --arg v "$(human "$val")" --arg f "$(human "$fee")" --arg h "$(human "$(to_dec "$held")")" \
        '{order_value_usd: $v, fee_usd: $f, tokens_available: $h}')
    fi
  fi
  if [ "$otype" = 1 ]; then   # a market order's value above is at its worst price; add it at today's price
    [ -n "$ref" ] || ref_maybe ref
    [ -z "$ref" ] || preview=$(echo "$preview" | jq --arg c "$(human "$(bc_int "$size * $ref / 10^18")")" '. + {value_at_current_price_usd: $c}')
  fi
  local fl; fl=$(jq -n --argjson m "$MAKER" --argjson i "$IOC" --argjson r "$REDUCE" '[(if $m then "maker-only" else empty end), (if $i then "immediate-or-cancel" else empty end), (if $r then "reduce-only" else empty end)]')
  summary="$side $(human "$size") $MNAME $([ $otype = 1 ] && echo "at market, no worse than $(usd "$price")" || echo "at $(usd "$price")")"
  [ $otype = 0 ] && ! $IOC && summary="$summary, rests $(duration_text $(( rest / 1000000 )))"
  jq -n --arg action "$side" --arg s "$summary" --arg book "$BOOK" --arg mname "$MNAME" --arg signed "$signed" --arg price "$price" \
    --argjson otype "$otype" --argjson flags "$flags" --argjson rest "$rest" --argjson pv "$preview" --argjson fl "$fl" \
    --arg size "$(human "$size")" --arg p "$(human "$price")" --arg type "$([ $otype = 1 ] && echo market || echo limit)" '
    {kind: "order", action: $action, summary: $s, market_name: $mname,
     call: {book: $book, size: $signed, price: $price, order_type: $otype, flags: $flags, rest_us: $rest},
     preview: ({market: $mname, side: $action, type: $type, size: $size,
                (if $type == "market" then "worst_price" else "price" end): $p, flags: $fl} + $pv)}' > "$T/plan"
  save_plan "$(cat "$T/plan")"
}

plan_close() {
  local q pct=100 pos abs size side price ref band val fee
  q=$(arg 0); [ -n "$q" ] || fail trade "Usage: pod trade close MARKET [--percent 50] [--price P]."
  need_wallet; load_market "$q" false
  [ "$MTYPE" = perp ] || fail trade "close is for perp positions. To sell spot tokens, use pod trade sell."
  account_numbers
  pos=$(position_of "$BOOK"); [ -n "$pos" ] && [ "$pos" != 0 ] || fail trade "No open position in $MNAME."
  pos=$(to_dec "$pos"); abs=${pos#-}
  [ -n "$PERCENT" ] && pct="$PERCENT"
  echo "$pct" | grep -Eq '^[0-9]+(\.[0-9]+)?$' && [ "$(echo "$pct > 0 && $pct <= 100" | bc)" = 1 ] || fail trade "--percent is a number above 0, up to 100."
  if [ "$(echo "$pct == 100" | bc)" = 1 ]; then size="$abs"; else size=$(floor_to "$(bc_int "$abs * ($pct * 100 / 1) / 10000")" "$LOT"); fi
  [ "$(bc_int "$size > 0")" = 1 ] || fail trade "$pct% of the position is smaller than the market's smallest step."
  case "$pos" in -*) side=buy ;; *) side=sell ;; esac
  local otype=1 flags=$(( FLAG_REDUCE_ONLY | FLAG_IOC ))
  if [ -n "$PRICE" ]; then
    otype=0; flags=$FLAG_REDUCE_ONLY
    local p_in; num_wei p_in "$PRICE" "Price"; price=$(round_price "$p_in" "$side")
    [ "$price" != "$p_in" ] && note "price $PRICE → $(human "$price") (rounded to the market's step, never worse than asked)"
  else
    band="${BAND:-$(setting market_band_pct)}"; check_band "$band"
    ref_price ref; price=$(band_price "$ref" "$side" "$band")
    note "worst price $(usd "$price"): the current price $(usd "$ref") $([ "$side" = buy ] && echo plus || echo minus) $band%"
  fi
  val=$(bc_int "$size * $price / 10^18"); fee=$(bc_int "$val * $TAKER_FEE / 10^18")
  local rest; rest_us rest "$RESTS" "$(setting default_ttl)"
  local signed; [ "$side" = buy ] && signed="$size" || signed="-$size"
  local what; what="$([ "$size" = "$abs" ] && echo "the whole position" || echo "$pct% of the position")"
  summary="close $what in $MNAME: $side $(human "$size") $([ $otype = 1 ] && echo "at market, no worse than $(usd "$price")" || echo "at $(usd "$price")")"
  jq -n --arg s "$summary" --arg book "$BOOK" --arg mname "$MNAME" --arg signed "$signed" --arg price "$price" \
    --argjson otype "$otype" --argjson flags "$flags" --argjson rest "$rest" --arg size "$(human "$size")" --arg held "$(human "$pos")" \
    --arg p "$(human "$price")" --arg v "$(human "$val")" --arg f "$(human "$fee")" --arg side "$side" '
    {kind: "order", action: "close", summary: $s, market_name: $mname,
     call: {book: $book, size: $signed, price: $price, order_type: $otype, flags: $flags, rest_us: $rest},
     preview: {market: $mname, position_now: $held, side: $side, size: $size,
               (if $otype == 1 then "worst_price" else "price" end): $p, flags: (["reduce-only"] + (if $otype == 1 then ["immediate-or-cancel"] else [] end)),
               order_value_usd: $v, fee_usd: $f, margin_needed_usd: "0 (it only shrinks the position)"}}' > "$T/plan"
  save_plan "$(cat "$T/plan")"
}

plan_cancel() {
  local id; id=$(arg 0); [ -n "$id" ] || fail trade "Usage: pod trade cancel ORDER_ID."
  need_wallet; find_open_order "$id"
  get /clob/markets "$T/markets"
  local name; name=$(pj -r --arg b "$(echo "$ORDER" | jq -r .orderbook_id)" 'include "pod"; market_map[$b] // $b' "$T/markets")
  echo "$ORDER" | pj --arg name "$name" 'include "pod";
    {kind: "cancel", action: "cancel", market_name: $name,
     summary: "cancel \(.side) \(.initial_size | amount | abs_str) \($name) at $\(.price | amount)",
     call: {book: .orderbook_id, order_id: .order_id},
     preview: {market: $name, order_id, side, size: (.initial_size | amount | abs_str), filled: (.filled_base_amount | amount),
               price: (.price | amount), status}}' > "$T/plan"
  save_plan "$(cat "$T/plan")"
}

plan_cancel_all() {
  local q; q=$(arg 0)
  need_wallet
  local filter=""
  if [ -n "$q" ]; then load_market "$q" "$SPOT"; filter="&orderbook=$BOOK"; else get /clob/markets "$T/markets"; fi
  echo '[]' > "$T/open"
  local st cursor
  for st in active pending; do
    cursor=""
    while :; do
      get "/clob/orders/$ADDR?status=$st&limit=500$filter${cursor:+&cursor=$cursor}" "$T/o"
      jq -s '.[0] + (.[1].orders // [])' "$T/open" "$T/o" > "$T/open.new" && mv "$T/open.new" "$T/open"
      cursor=$(jq -r '.next_cursor // empty' "$T/o"); [ -z "$cursor" ] && break
    done
  done
  local n; n=$(jq length "$T/open")
  if [ "$n" = 0 ]; then
    jq -n --arg w "$([ -n "$q" ] && echo " in $MNAME")" '{ok: true, nothing_to_do: true, summary: "No open orders\($w)."}'
    exit 0
  fi
  pj --arg q "$([ -n "$q" ] && echo "$MNAME")" 'include "pod"; . as $o | {kind: "cancel-all", action: "cancel-all", market_name: "",
    summary: "cancel \(if ($o | length) == 1 then "1 open order" else "all \($o | length) open orders" end)\(if $q == "" then "" else " in " + $q end)",
    call: {orders: [$o[] | {book: .orderbook_id, order_id}]},
    preview: {orders: ($o | length), transactions: ((($o | length) + 63) / 64 | floor),
              by_market: ($o | group_by(.orderbook_id) | map({key: .[0].orderbook_id, value: length}) | from_entries)}}' "$T/open" > "$T/plan"
  # name the markets
  jq --slurpfile m "$T/markets" -L "$HERE" 'include "pod"; ($m[0] | market_map) as $mm
    | .preview.by_market |= with_entries(.key = ($mm[.key] // .key))' "$T/plan" > "$T/plan.new" && mv "$T/plan.new" "$T/plan"
  save_plan "$(cat "$T/plan")"
}

plan_edit() {
  local id; id=$(arg 0); [ -n "$id" ] || fail trade "Usage: pod trade edit ORDER_ID [--price P] [--size S]."
  [ -n "$PRICE$SIZE_OPT" ] || fail trade "Say what to change: --price, --size, or both."
  need_wallet; find_open_order "$id"
  market_by_id "$(echo "$ORDER" | jq -r .orderbook_id)"
  local side old_price old_size price size
  side=$(echo "$ORDER" | jq -r .side)
  old_price=$(to_dec "$(echo "$ORDER" | jq -r .price)"); old_size=$(to_dec "$(echo "$ORDER" | jq -r .initial_size)"); old_size=${old_size#-}
  price=$old_price; size=$old_size
  if [ -n "$PRICE" ]; then
    local p_in; num_wei p_in "$PRICE" "Price"; price=$(round_price "$p_in" "$side")
    [ "$price" != "$p_in" ] && note "price $PRICE → $(human "$price") (rounded $([ "$side" = buy ] && echo down || echo up) to the market's step)"
  fi
  if [ -n "$SIZE_OPT" ]; then
    local s_in; num_wei s_in "$SIZE_OPT" "Size"; size=$(floor_to "$s_in" "$LOT")
    [ "$size" != "$s_in" ] && note "size $SIZE_OPT → $(human "$size") (rounded down to the market's step)"
    [ "$(bc_int "$size > 0")" = 1 ] || fail trade "Size $SIZE_OPT is smaller than the market's smallest step."
  fi
  local price_hex; price_hex="0x$(echo "obase=16; $price" | bc | tr -d '\\\n' | tr 'A-F' 'a-f')"
  jq -n --arg book "$BOOK" --arg id "$(echo "$ORDER" | jq -r .order_id)" --arg size "$size" --arg price "$price" --arg ph "$price_hex" \
    --arg mname "$MNAME" --arg side "$side" --arg op "$(human "$old_price")" --arg np "$(human "$price")" \
    --arg os "$(human "$old_size")" --arg ns "$(human "$size")" '
    {kind: "edit", action: "edit", market_name: $mname,
     summary: "change \($side) order on \($mname): price $\($op) → $\($np), size \($os) → \($ns)",
     call: {book: $book, order_id: $id, size: $size, price: $price, price_hex: $ph},
     preview: {market: $mname, order_id: $id, side: $side, price: "\($op) → \($np)", size: "\($os) → \($ns)",
               note: "the new size is the order'"'"'s new total size"}}' > "$T/plan"
  save_plan "$(cat "$T/plan")"
}

plan_trigger() {   # stop-loss | take-profit
  local which="$1" q pos abs side ttype trig limit ref band size signed ioc=false rest
  q=$(arg 0); [ -n "$q" ] && [ -n "$TRIG_PRICE" ] || fail trade "Usage: pod trade $which MARKET --trigger-price P [--limit-price P] [--size S]."
  need_wallet; load_market "$q" false
  [ "$MTYPE" = perp ] || fail trade "Stop-loss and take-profit work on perp positions here."
  account_numbers
  pos=$(position_of "$BOOK"); [ -n "$pos" ] && [ "$pos" != 0 ] || fail trade "No open position in $MNAME to protect."
  pos=$(to_dec "$pos"); abs=${pos#-}
  case "$pos" in -*) side=buy ;; *) side=sell ;; esac   # the closing side
  [ "$which" = stop-loss ] && ttype=$STOP_LOSS || ttype=$TAKE_PROFIT
  ref_price ref
  num_wei trig "$TRIG_PRICE" "Trigger price"
  local rtrig; rtrig=$(round_price "$trig" "$side"); [ "$rtrig" != "$trig" ] && note "trigger price $TRIG_PRICE → $(human "$rtrig") (rounded to the market's step)"; trig=$rtrig
  # A stop-loss must sit on the losing side of the current price, a take-profit on the winning side.
  local long; [ "$side" = sell ] && long=true || long=false
  if { [ "$which" = stop-loss ] && $long; } || { [ "$which" = take-profit ] && ! $long; }; then
    [ "$(bc_int "$trig < $ref")" = 1 ] || fail trade "For this $([ "$long" = true ] && echo long || echo short) position the $which must be below the current price $(usd "$ref"), or it would fire at once."
  else
    [ "$(bc_int "$trig > $ref")" = 1 ] || fail trade "For this $([ "$long" = true ] && echo long || echo short) position the $which must be above the current price $(usd "$ref"), or it would fire at once."
  fi
  if [ -n "$LIMIT_PRICE" ]; then
    local l_in; num_wei l_in "$LIMIT_PRICE" "Limit price"; limit=$(round_price "$l_in" "$side")
    [ "$limit" != "$l_in" ] && note "limit price $LIMIT_PRICE → $(human "$limit") (rounded to the market's step)"
  else
    band="${BAND:-$(setting market_band_pct)}"; check_band "$band"
    limit=$(band_price "$trig" "$side" "$band"); ioc=true
    note "when it fires it trades at market, no worse than $(usd "$limit") (the trigger price $([ "$side" = buy ] && echo plus || echo minus) $band%)"
  fi
  if [ -n "$SIZE_OPT" ]; then
    local s_in; num_wei s_in "$SIZE_OPT" "Size"; size=$(floor_to "$s_in" "$LOT")
    [ "$(bc_int "$size > 0 && $size <= $abs")" = 1 ] || fail trade "Size must be above 0 and at most the position ($(human "$abs"))."
    [ "$side" = buy ] && signed="$size" || signed="-$size"
  else
    size=0; signed=0   # with grouping "asset", pod sizes it from the whole position when it fires
  fi
  rest_us rest "$RESTS" "$TRIGGER_TTL_DEFAULT"
  local trig_hex; trig_hex="0x$(echo "obase=16; $trig" | bc | tr -d '\\\n' | tr 'A-F' 'a-f')"
  jq -n --arg which "$which" --arg side "$side" --arg book "$BOOK" --arg mname "$MNAME" --arg signed "$signed" --arg limit "$limit" --arg trig "$trig" \
    --arg th "$trig_hex" --argjson ttype "$ttype" --argjson g "$GROUP_ASSET" --argjson ioc "$ioc" --argjson rest "$rest" \
    --arg tp "$(human "$trig")" --arg lp "$(human "$limit")" --arg sz "$([ "$size" = 0 ] && echo "whole position" || human "$size")" \
    --arg held "$(human "$pos")" --arg now "$(human "$ref")" --arg rt "$(duration_text $(( rest / 1000000 )))" '
    {kind: "trigger", action: $which, market_name: $mname,
     summary: "\($which) on \($mname) at $\($tp) (\($sz))",
     call: {book: $book, size: $signed, limit_price: $limit, trigger_price: $trig, trigger_price_hex: $th,
            trigger_type: $ttype, grouping: $g, reduce_only: true, ioc: $ioc, rest_us: $rest, side: $side},
     preview: {market: $mname, position_now: $held, current_price: $now, trigger_price: $tp,
               then: (if $ioc then "market order, no worse than $\($lp)" else "limit order at $\($lp)" end),
               size: $sz, reduce_only: true, stays_armed_for: $rt,
               removed_when: "the position closes, or it is cancelled"}}' > "$T/plan"
  save_plan "$(cat "$T/plan")"
}

plan_edit_trigger() {
  local id; id=$(arg 0); [ -n "$id" ] || fail trade "Usage: pod trade edit-trigger TRIGGER_ID [--trigger-price P] [--limit-price P] [--size S]."
  [ -n "$TRIG_PRICE$LIMIT_PRICE$SIZE_OPT" ] || fail trade "Say what to change: --trigger-price, --limit-price or --size."
  need_wallet; find_trigger "$id"
  market_by_id "$(echo "$TRIG" | jq -r .orderbook_id)"
  local size limit trig side
  size=$(echo "$TRIG" | jq -r .size); limit=$(to_dec "$(echo "$TRIG" | jq -r .limit_price)"); trig=$(to_dec "$(echo "$TRIG" | jq -r .trigger_price)")
  account_numbers
  local pos; pos=$(to_dec "$(position_of "$BOOK")"); case "$pos" in -*) side=buy ;; *) side=sell ;; esac
  if [ -n "$TRIG_PRICE" ]; then num_wei trig "$TRIG_PRICE" "Trigger price"; trig=$(round_price "$trig" "$side"); fi
  if [ -n "$LIMIT_PRICE" ]; then num_wei limit "$LIMIT_PRICE" "Limit price"; limit=$(round_price "$limit" "$side"); fi
  if [ -n "$SIZE_OPT" ]; then
    local s; num_wei s "$SIZE_OPT" "Size"; s=$(floor_to "$s" "$LOT"); [ "$side" = buy ] && size="$s" || size="-$s"
  fi
  local trig_hex; trig_hex="0x$(echo "obase=16; $trig" | bc | tr -d '\\\n' | tr 'A-F' 'a-f')"
  echo "$TRIG" | pj --arg mname "$MNAME" --arg side "$side" --arg size "$size" --arg limit "$limit" --arg trig "$trig" --arg th "$trig_hex" 'include "pod";
    {kind: "edit-trigger", action: "edit-trigger", market_name: $mname,
     summary: "change \(.trigger_type | sub("_"; "-")) on \($mname): trigger $\(.trigger_price | amount) → $\($trig | amount)",
     call: {book: .orderbook_id, trigger_id: .order_id, size: $size, limit_price: $limit, trigger_price: $trig, trigger_price_hex: $th, side: $side},
     preview: {market: $mname, trigger_id: .order_id, type: .trigger_type,
               trigger_price: "\(.trigger_price | amount) → \($trig | amount)", limit_price: "\(.limit_price | amount) → \($limit | amount)",
               size: "\(.size | amount | abs_str) → \($size | amount | abs_str)"}}' > "$T/plan"
  save_plan "$(cat "$T/plan")"
}

plan_cancel_trigger() {
  local id; id=$(arg 0); [ -n "$id" ] || fail trade "Usage: pod trade cancel-trigger TRIGGER_ID."
  need_wallet; find_trigger "$id"
  market_by_id "$(echo "$TRIG" | jq -r .orderbook_id)"
  echo "$TRIG" | pj --arg mname "$MNAME" 'include "pod";
    {kind: "cancel-trigger", action: "cancel-trigger", market_name: $mname,
     summary: "remove the \(.trigger_type | sub("_"; "-")) on \($mname) at $\(.trigger_price | amount)",
     call: {book: .orderbook_id, trigger_id: .order_id},
     preview: {market: $mname, trigger_id: .order_id, type: .trigger_type, trigger_price: (.trigger_price | amount)}}' > "$T/plan"
  save_plan "$(cat "$T/plan")"
}

[ -z "$USD" ] || case "$ACTION" in buy|sell) ;; *) fail trade "--usd is for buy and sell." "Use --percent to close part of a position." ;; esac
case "$ACTION" in
  buy|sell)              plan_order "$ACTION" ;;
  close)                 plan_close ;;
  cancel)                plan_cancel ;;
  cancel-all)            plan_cancel_all ;;
  edit)                  plan_edit ;;
  stop-loss|take-profit) plan_trigger "$ACTION" ;;
  edit-trigger)          plan_edit_trigger ;;
  cancel-trigger)        plan_cancel_trigger ;;
  send)                  [ -n "$(arg 0)" ] || fail trade "Usage: pod trade send PLAN_ID."; do_send "$(arg 0)" ;;
  follow)                [ -n "$(arg 0)" ] || fail trade "Usage: pod trade follow PLAN_ID [--timeout 30]."
                         case "$TIMEOUT" in ''|*[!0-9]*) fail trade "--timeout is whole seconds." ;; esac
                         do_follow "$(arg 0)" "$TIMEOUT" ;;
  "") fail_usage trade "Name an action." "buy, sell, close, edit, cancel, cancel-all, stop-loss, take-profit, edit-trigger, cancel-trigger, send, follow." ;;
  *)  fail_usage trade "Unknown action '$ACTION'." "buy, sell, close, edit, cancel, cancel-all, stop-loss, take-profit, edit-trigger, cancel-trigger, send, follow." ;;
esac
