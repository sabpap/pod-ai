#!/usr/bin/env bash
# What an account holds, what it is worth and what it has done. Read-only; works for any address.
# Spec: specs/04-account.md.
#
#: pod account: what an account holds, what it is worth and what it has done.
#:
#: Usage:
#:   pod account [VIEW] [ADDRESS] [--since WHEN] [--limit N] [--status STATUS] [--raw]
#:
#: ADDRESS defaults to the connected wallet. Any 0x address can be read: pod's account data is
#: public, and no key is needed. Nothing here sends a transaction.
#:
#: Pick the view from the question:
#:   "what do I have?", "what's my balance?"           overview (the default)
#:   "what are my positions?", "am I near liquidation?"  positions
#:   "what orders are open?"                            orders
#:   "what did I buy and sell?", "what did I pay in fees?"  trades
#:   "which stops and targets are set?"                 triggers
#:   "what happened on my account?"                     activity
#:   "was I liquidated?"                                forced-closes
#:   "how did this week go?", "profit since Monday?"     results
#:
#: Options:
#:   --since WHEN   only entries after this time: 30m, 24h, 7d, 2026-11-01 or 2026-11-01T12:00:00Z
#:                  (UTC). For trades, activity and results (results default 7d)
#:   --limit N      how many entries, 1 to 5000, newest first. Default 50. For orders, trades,
#:                  triggers, activity and forced-closes
#:   --status S     orders only: open (default), all, or one of pending, active, filled, expired,
#:                  canceled, margin_canceled, self_trade_canceled, post_only_refused, settled, invalid
#:   --raw          pod's answers unchanged, page by page. Only when pod's own data is asked for, or a
#:                  field is needed that the views leave out
#:
#: Output: ok, view, account, connected (true when it is the connected wallet), as_of, data; list
#: views add count and more; computed names the fields pod works out rather than reads.
#:   more: true     more entries exist beyond --limit: say so, and offer a larger --limit or a --since
#:
#: How to read the numbers:
#:   Amounts are exact decimal strings, in USD (fields ending _usd) or in units of the asset (size).
#:   Account value is what the account is worth: cash plus unrealized profit or loss (and spot
#:   holdings at their price). It answers "how much do I have". Cash alone does not: a perp position
#:   only holds part of the cash as collateral (margin).
#:   computed: margin in use, free margin, real leverage, lifetime profit or loss, return on margin,
#:   distance to liquidation and the results totals are worked out from pod's data. Say "about" or
#:   "worked out from pod's data" when quoting them.
#:   liquidation_price: null means the position has none at its current size and margin. Not $0.
#:   pod_leverage on a position is pod's figure for that position alone (value / margin).
#:   real_leverage in the overview is the whole account's: all positions' value / account value.
#:   funding_owed_usd: positive means the account owes funding on that position; negative, it is owed.
#:   Pod keeps no funding history, so funding on closed positions is not visible.
#:   results.realized_pnl_usd adds up the profit or loss pod recorded on each trade in the window;
#:   results.lifetime comes from pod directly.
#:
#: Fields by view:
#:   overview    account_value_usd, cash_usd, unrealized_pnl_usd, realized_pnl_lifetime_usd,
#:               lifetime_pnl_usd, withdrawable_usd, net_deposits_usd, margin_in_use_usd,
#:               free_margin_usd, real_leverage, open_positions, spot_holdings, open_orders, holdings
#:   positions   market, side, size, entry_price, mark_price, value_usd, margin_usd, pod_leverage,
#:               unrealized_pnl_usd, return_on_margin_pct, funding_owed_usd, liquidation_price,
#:               liquidation_distance_pct; spot holdings: size, free, locked_in_orders, cost_basis_usd
#:   orders      market, side, direction, type, size, filled_size, price, average_fill_price, status,
#:               flags, fee_usd, realized_pnl_usd, joined_book, deadline, ends, order_id, tx_hash
#:   trades      time, market, side, size, price, value_usd, fee_usd, type, order_id
#:   triggers    market, type, side, size ("whole position" when it closes all), trigger_price,
#:               limit_price, flags, ends, order_id (the trigger id for pod trade edit-trigger)
#:   activity    time, kind (order, fill, termination, modify, backstop, settlement,
#:               bridge_transfer, transfer, ...), description (one plain sentence), order_id, tx, market
#:   forced-closes  time, market, size, cash_usd, mark_price, equity_usd, realized_pnl_usd
#:   results     trades, traded_value_usd, fees_paid_usd, realized_pnl_usd, deposits_usd,
#:               withdrawals_usd, transfers_in_usd, transfers_out_usd, forced_closes, settlements,
#:               lifetime, funding_owed_on_open_positions_usd
#:
#: Answer the question asked in a few lines or a small table; do not paste the JSON. Quote amounts to
#: a sensible precision and keep the sign. Name the account when it is not the connected wallet.
#:
#: When it fails: "Pod answered ... with an error (503: clob indexer unavailable)" means pod's history
#: service is down: trades, activity and results cannot be read until it is back, while overview,
#: positions and orders usually still work.

source "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"

VIEWS="overview positions orders trades triggers activity forced-closes results"
STATUSES="pending active filled expired canceled margin_canceled self_trade_canceled post_only_refused settled invalid"

view="overview"; addr=""; since=""; limit=50; status="open"; raw=false
while [ $# -gt 0 ]; do
  case "$1" in
    --since) since="${2:-}"; shift 2 || fail account "--since needs a value, e.g. 7d." ;;
    --limit) limit="${2:-}"; shift 2 || fail account "--limit needs a number." ;;
    --status) status="${2:-}"; shift 2 || fail account "--status needs a value." ;;
    --raw) raw=true; shift ;;
    0x*|0X*) addr="$1"; shift ;;
    -*) fail_usage account "Unknown option $1." "Options: --since, --limit, --status, --raw. See pod account --help." ;;
    *) case " $VIEWS " in
         *" $1 "*) view="$1"; shift ;;
         *) fail_usage account "Unknown view '$1'." "Views: $VIEWS. See pod account --help." ;;
       esac ;;
  esac
done

case "$limit" in ''|*[!0-9]*) fail account "--limit must be a whole number from 1 to 5000." ;; esac
{ [ "$limit" -ge 1 ] && [ "$limit" -le 5000 ]; } || fail account "--limit must be a whole number from 1 to 5000."
if [ "$view" = orders ]; then
  case " open all $STATUSES " in *" $status "*) ;; *) fail account "Unknown order status '$status'." "Use open, all, or one of: $STATUSES." ;; esac
fi

# --- whose account ------------------------------------------------------------------------------------

connected=false
if [ -z "$addr" ]; then
  profile_exists || fail account "No address was named and no wallet is connected." "Name an address, or connect a wallet with pod setup."
  addr=$(profile_get '.wallet.address')
fi
echo "$addr" | grep -Eq '^0[xX][0-9a-fA-F]{40}$' || fail account "'$addr' is not an account address (0x and 40 hex characters)."
if profile_exists && [ "$(echo "$addr" | tr 'A-F' 'a-f')" = "$(profile_get '.wallet.address' | tr 'A-F' 'a-f')" ]; then
  connected=true
fi

[ "$view" = results ] && [ -z "$since" ] && since="7d"
SINCE_US=""
if [ -n "$since" ]; then
  SINCE_US=$(since_us "$since") || fail account "'$since' is not a time I understand." "Use 30m, 24h, 7d, 2026-11-01 or 2026-11-01T12:00:00Z."
fi

# --- fetching and paging -------------------------------------------------------------------------------------

T=$(mktemp -d "${TMPDIR:-/tmp}/pod-account.XXXXXX")
trap 'rm -rf "$T"' EXIT
echo '[]' > "$T/items"; echo '[]' > "$T/pages"
more=false

fetch() { fetch_to account "$1" "$2"; }   # fetch PATH FILE (lib.sh)

keep_page() {   # keep_page FILE ITEMS_JQ: append a response to the raw pages and its items to the list
  jq -s '.[0] + [.[1]]' "$T/pages" "$1" > "$T/p.new" && mv "$T/p.new" "$T/pages"
  jq -s ".[0] + (.[1] | $2)" "$T/items" "$1" > "$T/i.new" && mv "$T/i.new" "$T/items"
}
count() { jq length "$T/items"; }
per_page() { local p=$(( limit - $(count) )); [ "$p" -gt "$1" ] && p=$1; echo "$p"; }

page_cursor() {   # page_cursor ROUTE ITEMS_KEY MAX_PER_PAGE: pod's cursor paging (orders, triggers, forced closes)
  local route="$1" key="$2" max="$3" cursor="" sep="?" p
  case "$route" in *\?*) sep="&" ;; esac
  while :; do
    if [ "$(count)" -ge "$limit" ]; then [ -n "$cursor" ] && more=true; break; fi
    p=$(per_page "$max")
    fetch "$route${sep}limit=$p${cursor:+&cursor=$cursor}" "$T/resp"
    keep_page "$T/resp" ".$key // []"
    cursor=$(jq -r '.next_cursor // empty' "$T/resp")
    [ -z "$cursor" ] && break
  done
}

page_fills() {   # newest first, at most 500 per window [from_us, to_us), no cursor
  # Every fill of one auction round shares its timestamp, and a full page can stop in the middle
  # of a round. So the page's oldest round is dropped and read again, whole, by the next window,
  # which ends just after it.
  local to="" p got q oldest newest
  while :; do
    if [ "$(count)" -ge "$limit" ]; then more=true; break; fi
    p=$(per_page 500)
    q="limit=$p${SINCE_US:+&from_us=$SINCE_US}${to:+&to_us=$to}"
    fetch "/clob/fills/$addr?$q" "$T/resp"
    keep_page "$T/resp" ".fills // []"
    got=$(jq '.fills | length' "$T/resp")
    [ "$got" -lt "$p" ] && break
    oldest=$(jq '[.fills[].timestamp] | min' "$T/resp")
    newest=$(jq '[.fills[].timestamp] | max' "$T/resp")
    if [ "$oldest" = "$newest" ]; then more=true; break; fi   # one round fills the page: cannot page past it
    jq --argjson t "$oldest" 'map(select(.timestamp != $t))' "$T/items" > "$T/i.new" && mv "$T/i.new" "$T/items"
    to=$(( oldest + 1 ))
  done
}

page_activity() {   # newest first, whole rounds per page; ACTIVITY_TYPES narrows the kinds
  local to="" p q
  while :; do
    if [ "$(count)" -ge "$limit" ]; then [ -n "$to" ] && more=true; break; fi
    p=$(per_page 500)   # bigger pages time out on busy accounts
    q="limit=$p${SINCE_US:+&from=$SINCE_US}${to:+&to=$to}${ACTIVITY_TYPES:+&activity_types=$ACTIVITY_TYPES}"
    fetch "/clob/activity/$addr?$q" "$T/resp"
    keep_page "$T/resp" '[.activity // {} | to_entries[] | .key as $t | .value[] | {ts: $t} + .] | sort_by(-(.ts | tonumber))'
    to=$(jq -r '.next // empty' "$T/resp")
    [ -z "$to" ] && break
  done
  if [ "$(count)" -gt "$limit" ]; then
    jq ".[0:$limit]" "$T/items" > "$T/i.new" && mv "$T/i.new" "$T/items"; more=true
  fi
}

# --- read ---------------------------------------------------------------------------------------------------------

computed='[]'
case "$view" in
  overview)
    fetch "/clob/positions/$addr" "$T/positions"; keep_page "$T/positions" '[]'
    fetch "/clob/balances/$addr" "$T/balances"; keep_page "$T/balances" '[]'
    fetch "/clob/orders/$addr?status=active&limit=1" "$T/active"; keep_page "$T/active" '[]'
    fetch "/clob/orders/$addr?status=pending&limit=1" "$T/pending"; keep_page "$T/pending" '[]'
    computed='["margin_in_use_usd","free_margin_usd","real_leverage","lifetime_pnl_usd"]' ;;
  positions)
    fetch "/clob/positions/$addr" "$T/positions"; keep_page "$T/positions" '[]'
    fetch "/clob/balances/$addr" "$T/balances"; keep_page "$T/balances" '[]'
    computed='["return_on_margin_pct","liquidation_distance_pct"]' ;;
  orders)
    case "$status" in
      open) page_cursor "/clob/orders/$addr?status=pending" orders 500
            page_cursor "/clob/orders/$addr?status=active" orders 500 ;;
      all)  page_cursor "/clob/orders/$addr" orders 500 ;;
      *)    page_cursor "/clob/orders/$addr?status=$status" orders 500 ;;
    esac ;;
  trades)        page_fills ;;
  triggers)      page_cursor "/clob/triggers/$addr" triggers 200 ;;
  forced-closes) page_cursor "/clob/backstop-transfers/$addr" backstop_transfers 200 ;;
  activity)      page_activity ;;
  results)
    limit=5000
    ACTIVITY_TYPES="fill,bridge_transfer,transfer,backstop,settlement"
    page_activity
    fetch "/clob/positions/$addr" "$T/positions"; keep_page "$T/positions" '[]'
    computed='["trades","traded_value_usd","fees_paid_usd","realized_pnl_usd","deposits_usd","withdrawals_usd","transfers_in_usd","transfers_out_usd","lifetime_pnl_usd","funding_owed_on_open_positions_usd"]' ;;
esac

base() {   # the envelope every answer shares
  jq -n --arg view "$view" --arg a "$addr" --argjson c "$connected" --arg at "$(now_iso)" \
    --arg since "$since" --arg sus "$SINCE_US" -L "$HERE" 'include "pod";
    {ok: true, view: $view, account: $a, connected: $c, as_of: $at}
    + (if $since == "" then {} else {since: ($sus | us_time)} end)'
}

if $raw; then
  base | jq --slurpfile p "$T/pages" '. + {raw: $p[0]}'
  exit 0
fi

fetch /clob/markets "$T/markets"

# --- shape -------------------------------------------------------------------------------------------------------

JQ_DEFS='
include "pod";
($m[0] | market_map) as $mm |
def nonull: with_entries(select(.value != null and .value != [] and .value != ""));
def mname: . as $id | ($mm[$id] // $id);
def num: tonumber;
def usd: if . == null then null elif startswith("-") then "-$" + .[1:] else "$" + . end;
def flags: [ (if .post_only then "maker-only" else empty end), (if .ioc then "immediate-or-cancel" else empty end),
             (if .reduce_only then "reduce-only" else empty end) ];
def position:
  (.mark_price | amount | num) as $mark | (.liquidation_price | price_or_null) as $liq
  | (.margin | amount | num) as $margin
  | {kind: "perp", market: (.orderbook_id | mname), side, size: (.size | amount | abs_str),
     entry_price: (.entry_price | amount), mark_price: (.mark_price | amount),
     value_usd: (.notional | amount), margin_usd: (.margin | amount),
     pod_leverage: (.leverage | amount | num | fixed(2)),
     unrealized_pnl_usd: (.unrealized_pnl | amount),
     return_on_margin_pct: (if $margin > 0 then ((.unrealized_pnl | amount | num) / $margin * 100 | fixed(2)) else null end),
     funding_owed_usd: (.funding_accrued | amount),
     liquidation_price: $liq,
     liquidation_distance_pct: (if $liq == null or $mark == 0 then null
        elif .side == "long" then (($mark - ($liq | num)) / $mark * 100 | fixed(2))
        else ((($liq | num) - $mark) / $mark * 100 | fixed(2)) end),
     market_id: .orderbook_id};
def holding:
  {kind: "spot", market: (.orderbook_id | mname), size: (.balance | amount), free: (.free_balance | amount),
   locked_in_orders: (.locked_balance | amount), mark_price: (.mark_price | amount),
   cost_basis_usd: (.cost_basis | amount), unrealized_pnl_usd: (.unrealized_pnl | amount), market_id: .orderbook_id} | nonull;
def order:
  {market: (.orderbook_id | mname), side, direction, kind: (if .kind == "user_signed" then null else .kind end),
   type: .order_type, size: (.initial_size | amount | abs_str), filled_size: (.filled_base_amount | amount),
   price: (.price | amount), average_fill_price: (.effective_price | price_or_null), status, invalid_reason,
   fee_usd: (.fee | amount), realized_pnl_usd: (.realized_pnl | amount), flags: flags, trigger_type,
   joined_book: (.included_batch | if . == 0 or . == null then null else us_time end),
   deadline: (.deadline | us_time), ends: (.end | us_time), order_id, tx_hash} | nonull;
'

case "$view" in
  overview)
    jq -n -L "$HERE" --slurpfile m "$T/markets" --slurpfile p "$T/positions" --slurpfile b "$T/balances" \
      --slurpfile ao "$T/active" --slurpfile po "$T/pending" "$JQ_DEFS"'
      $p[0] as $P | $b[0] as $B
      | ([$P.positions[] | .margin | amount | num] | add // 0) as $margin
      | ([$P.positions[] | .notional | amount | num] | add // 0) as $notional
      | ($P.account_value | amount | num) as $value
      | {account_value_usd: ($P.account_value | amount), cash_usd: ($P.cash | amount),
         unrealized_pnl_usd: ($P.total_unrealized_pnl | amount),
         realized_pnl_lifetime_usd: ($P.total_realized_pnl | amount),
         lifetime_pnl_usd: (($value - ($P.net_deposits | amount | num)) | fixed(8)),
         withdrawable_usd: ($P.withdrawable_cash | amount), net_deposits_usd: ($P.net_deposits | amount),
         margin_in_use_usd: ($margin | fixed(8)), free_margin_usd: (($value - $margin) | fixed(8)),
         real_leverage: (if $value > 0 then ($notional / $value | fixed(4)) else null end),
         open_positions: ($P.positions | length), spot_holdings: ($B.balances | length),
         open_orders: (($ao[0].total_count // 0) + ($po[0].total_count // 0)),
         holdings: ([$P.positions[] | position | "\(.side) \(.size) \(.market) · value \(.value_usd | usd) · profit or loss \(.unrealized_pnl_usd | usd)"]
                   + [$B.balances[] | holding | "\(.size) \(.market) at $\(.mark_price)"])}' > "$T/data" ;;
  positions)
    jq -n -L "$HERE" --slurpfile m "$T/markets" --slurpfile p "$T/positions" --slurpfile b "$T/balances" "$JQ_DEFS"'
      [$p[0].positions[] | position] + [$b[0].balances[] | holding]' > "$T/data" ;;
  orders)
    jq -L "$HERE" --slurpfile m "$T/markets" "$JQ_DEFS"'[.[] | order]' "$T/items" > "$T/data" ;;
  trades)
    jq -L "$HERE" --slurpfile m "$T/markets" "$JQ_DEFS"'[.[] |
      {time: (.timestamp | us_time), market: (.orderbook_id | mname),
       side: (if (.initial_size | tostring | startswith("-")) then "sell" else "buy" end),
       size: (.base_amount | amount), price: (.price | amount), value_usd: (.quote_amount | amount),
       fee_usd: (.fee | amount), type: .order_type, order_id} | nonull]' "$T/items" > "$T/data" ;;
  triggers)
    jq -L "$HERE" --slurpfile m "$T/markets" "$JQ_DEFS"'[.[] |
      {market: (.orderbook_id | mname), type: .trigger_type,
       side: (if (.size | int_str) == "0" then "closes the position"
              elif (.size | tostring | startswith("-")) then "sell" else "buy" end),
       size: (if (.size | int_str) == "0" then "whole position" else (.size | amount | abs_str) end),
       trigger_price: (.trigger_price | amount), limit_price: (.limit_price | price_or_null),
       grouping, flags: flags, deadline: (.deadline | us_time), ends: (.end | us_time), order_id, tx_hash} | nonull]' "$T/items" > "$T/data" ;;
  forced-closes)
    jq -L "$HERE" --slurpfile m "$T/markets" "$JQ_DEFS"'[.[] |
      {time: (.timestamp_us | us_time), market: (if .orderbook_id then (.orderbook_id | mname) else "cash sweep" end),
       size: (.size | amount), cash_usd: (.cash | amount), mark_price: (.mark_price | amount),
       equity_usd: (.equity | amount), realized_pnl_usd: (.realized_pnl | amount)} | nonull]' "$T/items" > "$T/data" ;;
  activity)
    jq -L "$HERE" --slurpfile m "$T/markets" "$JQ_DEFS"'
      def money: amount | usd;
      def describe:
        if .k == "order" then (order) as $o
          | "\(if $o.kind then $o.kind + " " else "" end)order: \($o.side) \($o.size) \($o.market) at $\($o.price) (\([$o.type] + $o.flags | join(", "))) · now \($o.status)"
        elif .k == "fill" then
          "filled: \(.b | amount) \(.book | mname) for \(.q | money)"
          + (if .f then ", fee \(.f | money)" else "" end)
          + (if .pnl then ", realized \(.pnl | money)" else "" end)
          + (if .st then " · order \(.st)" else "" end)
        elif .k == "modify" then "order changed: price $\(.old_px | amount) → $\(.px | amount), size \(.old_sz | amount) → \(.sz | amount)"
        elif .k == "termination" then "order \(.st) · \(.book | mname)" + (if .expr == "ttl" then " (reached its end time)" elif .expr == "ioc" then " (unfilled rest of an immediate-or-cancel order)" else "" end)
        elif .k == "backstop" then (if .book then "forced close: \(.sz | amount) \(.book | mname) moved to the backstop at $\(.mark | amount)" else "forced close: remaining cash swept to the backstop" end) + ", equity \(.eq | money), realized \(.pnl | money)"
        elif .k == "settlement" then "market settled: position \(.sz | amount) \(.book | mname) closed at $\(.px | amount), realized \(.pnl | money)"
        elif .k == "bridge_transfer" then (if (.amt | startswith("-")) then "withdrawal \(.amt | amount | abs_str | usd)" else "deposit \(.amt | money)" end) + (if .err then " · refused: \(.err)" else "" end)
        elif .k == "transfer" then (if (.amt | startswith("-")) then "sent \(.amt | amount | abs_str | usd) to \(.cp)" else "received \(.amt | money) from \(.cp)" end) + (if .err then " · refused: \(.err)" else "" end)
        elif .k == "modify_reject" then "order change refused: \(.why)"
        elif .k == "cancel_reject" then "cancel refused: \(.why)"
        else .k end;
      [.[] | {time: (.ts | us_time), kind: .k, description: describe,
              order_id: (if .k == "order" then .order_id else .id end), tx: (.tx_hash // .tx),
              market: ((.orderbook_id // .book) | if . == null then null else mname end)} | nonull]' "$T/items" > "$T/data" ;;
  results)
    jq -n -L "$HERE" --slurpfile m "$T/markets" --slurpfile a "$T/items" --slurpfile p "$T/positions" "$JQ_DEFS"'
      def total(f): (map(f | select(. != null) | amount | num) | add // 0);
      $a[0] as $A | $p[0] as $P
      | [$A[] | select(.k == "fill")] as $fills
      | [$A[] | select(.k == "bridge_transfer" and (.err | not))] as $bridge
      | [$A[] | select(.k == "transfer" and (.err | not))] as $xfer
      | {trades: ($fills | length),
         traded_value_usd: ($fills | total(.q) | fixed(8)),
         fees_paid_usd: ($fills | total(.f) | fixed(8)),
         realized_pnl_usd: ($fills | total(.pnl) | fixed(8)),
         deposits_usd: ([$bridge[] | select(.amt | startswith("-") | not)] | total(.amt) | fixed(8)),
         withdrawals_usd: ([$bridge[] | select(.amt | startswith("-"))] | total(.amt | ltrimstr("-")) | fixed(8)),
         transfers_in_usd: ([$xfer[] | select(.amt | startswith("-") | not)] | total(.amt) | fixed(8)),
         transfers_out_usd: ([$xfer[] | select(.amt | startswith("-"))] | total(.amt | ltrimstr("-")) | fixed(8)),
         forced_closes: ([$A[] | select(.k == "backstop")] | length),
         settlements: ([$A[] | select(.k == "settlement")] | length),
         lifetime: {realized_pnl_usd: ($P.total_realized_pnl | amount),
                    unrealized_pnl_usd: ($P.total_unrealized_pnl | amount),
                    lifetime_pnl_usd: ((($P.account_value | amount | num) - ($P.net_deposits | amount | num)) | fixed(8))},
         funding_owed_on_open_positions_usd: ([$P.positions[] | .funding_accrued] | total(.) | fixed(8)),
         notes: ["funding_owed: positive means the account owes it. Pod keeps no funding history, so funding on closed positions is not included."]}' > "$T/data" ;;
esac

list=false
case "$view" in overview|results) ;; *) list=true ;; esac

base | jq --slurpfile d "$T/data" --argjson more "$more" --argjson list "$list" --argjson computed "$computed" '
  . + (if $list then {count: ($d[0] | length), more: $more} else {} end)
    + (if $computed == [] then {} else {computed: $computed} end)
    + (if $more and .view == "results" then {warning: "More than 5000 entries in the window: totals cover the newest 5000 only."} else {} end)
    + {data: $d[0]}'
