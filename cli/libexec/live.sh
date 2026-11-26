#!/usr/bin/env bash
# Follow pod live. Checks the arguments, resolves names and accounts, then hands over to live.mjs.
# Needs Node.js 22 or later (its built-in WebSocket). Spec: specs/07-live.md.
#
#: pod live: follow pod as it changes, and be told the moment a condition holds.
#:
#: Usage:
#:   pod live CHANNEL [MARKET... | ADDRESS...] [--until "FIELD OP VALUE"]... [--every 30s] [--for 2h] [options]
#:   pod live list            the listeners running on this machine
#:   pod live stop ID|all     stop one listener, or all of them
#:
#: A listener holds pod's WebSocket open and prints one JSON line per update. It only reads and
#: never trades. It runs until a condition holds, --for runs out, it is stopped, or its process ends.
#: It is long-running: run it in the background, or give it --for. Needs Node.js 22 or later.
#:
#: Channels:
#:   market MARKET...       price (mark on perps, last traded on spot), 24-hour numbers, funding, open
#:                          interest. Changes, at most every 30 s
#:   book MARKET...         best bid and ask, spread; --depth N adds N levels per side. Changes, every 30 s
#:   bars MARKET...         one price bar (open, high, low, close, volume) per --every window, built from
#:                          each round. One bar per 30 s in which something traded or the price moved
#:   orders [ADDRESS...]    order events: new, filled (partly or fully), cancelled, expired, refused,
#:                          changed. Up to 64 accounts. Every change
#:   positions [ADDRESS]    account value, cash and the positions; with --market NVDA, that one position.
#:                          Every change, starting with the current state
#:   triggers [ADDRESS]     the armed stop-losses and take-profits. Every change, starting with the list
#:   activity [ADDRESS]     everything that happens on the account, each with a plain description
#:   receipts [ADDRESS] [--tx HASH]...   whether sent transactions succeeded; with --tx it ends by
#:                          itself when every receipt has arrived
#:   rounds                 pod's auction rounds (two a second), counted per 30 s
#:   ADDRESS defaults to the connected wallet.
#:
#: Options:
#:   --until "FIELD OP VALUE"   stop and report the update where this holds; repeat for "any of these"
#:   --every 30s | 0            at most one line per window, and only when something changed;
#:                              0 = every update (two a second on a busy market)
#:   --for 2h                   stop after this long, 1s to 30d (default: until stopped)
#:   --market NAME              orders, positions, triggers, activity: only this market
#:   --order ID                 orders, activity: only this order (0x and 64 hex characters)
#:   --tx HASH                  receipts: these transactions; repeat for several
#:   --depth N                  book: levels per side, 1 to 50
#:   --spot                     pick the spot market when a name has both
#:   --raw                      pod's messages unchanged (no conditions)
#:
#: Conditions: --until "FIELD OP VALUE" ends the listener on the first update where it holds.
#: Operators: <, <=, >, >=, =, !=. Numbers compare as numbers; text compares without case. Conditions
#: are tested on every update, whatever --every says. Fields (short names in brackets):
#:   market      price, mark_price (mark), last_price (last), oracle_price (oracle), change_24h_pct
#:               (change), funding_rate_pct (funding), mark_vs_oracle_pct, open_interest_usd,
#:               volume_24h_usd, high_24h, low_24h, status
#:   book        best_bid (bid), best_ask (ask), mid, spread, spread_pct, bid_size, ask_size
#:   bars        price, volume (of each round)
#:   orders      status (resting, partly filled, filled, canceled, expired, refused), event, side,
#:               fill_price, filled_size, total_filled, order_id
#:   positions   account_value_usd, cash_usd, unrealized_pnl_usd (pnl), positions; with --market:
#:               size, side, mark_price, unrealized_pnl_usd, liquidation_distance_pct
#:   triggers    count
#:   activity    kind (order, fill, termination, ...), status, position_after, realized_pnl_usd
#:   receipts    ok
#:   rounds      round
#:
#: Examples:
#:   "tell me when NVDA trades below 140"      pod live market NVDA --until "mark < 140"
#:   "let me know when order 0xab… fills"      pod live orders --order 0xab… --until "status = filled"
#:   "tell me if my NVDA position closes"      pod live positions --market NVDA --until "size = 0"
#:   "warn me within 5% of liquidation"        pod live positions --market NVDA --until "liquidation_distance_pct < 5"
#:   "alert me if the gold spread passes 0.5%"  pod live book gold --until "spread_pct > 0.5"
#:   "keep me posted on NVDA for 30 minutes"   pod live market NVDA --for 30m
#: A stop-loss or take-profit on a position needs no listener: pod watches it itself (pod trade stop-loss).
#: Acting on a condition is a separate step; a trade still goes through pod trade and its approval.
#:
#: Lines it prints:
#:   "event": "watching"         the first line: id, channel, what, until, every, for, and the stop command.
#:                               Tell the person in one line what is running and its id
#:   an update                   plain numbers, like pod markets and pod account: amounts as exact
#:                               decimal strings, times in UTC
#:   "event": "notice"           the connection dropped or pod closed the stream. The listener reconnects
#:                               and catches up from the last round it saw, so nothing is missed; if pod
#:                               no longer holds the missed rounds (about 2.3 hours are kept), it says so
#:   "event": "condition met"    the last line: the condition and the update that matched (exit 0)
#:   "event": "stopped"          the last line: reason (time up, stopped on request, every receipt arrived)
#:   "ok": false                 refused before starting, with error and fix (exit 1 or 2)
#: Stop listeners that are no longer needed: pod live list, pod live stop ID (or all).
#:
#: Pod's live protocol, for a web page, a dashboard or another program that talks to pod directly
#: (pod live already follows these rules):
#:   1. Always subscribe with "since". Without it, pod_markets, pod_positions and pod_triggers send
#:      nothing until something changes: on a quiet account a positions view stays empty, possibly for
#:      hours, while the subscription looks healthy. So: read the matching REST route first and draw
#:      the current state from it (/v1/clob/positions/{account}, /v1/clob/triggers/{account},
#:      /v1/clob/markets/stats, /v1/clob/orderbook/{id}); take that answer's round time ("timestamp"
#:      on positions, triggers and the book; "solution_now" on the others, also from
#:      GET /v1/clob/status); subscribe with since set to it, as a JSON number (a string is refused).
#:      Pod keeps about 2.3 hours; an older since is refused with "since too old".
#:   2. Connect to wss://staging-rpc.podtestnet.dev and send
#:      {"jsonrpc":"2.0","id":1,"method":"eth_subscribe","params":["<channel>",{options}]}.
#:      Updates arrive as eth_subscription notifications after each auction round.
#:   3. Channels: pod_markets, pod_orderbook (depth), pod_candles, pod_orders_v2 (bidder or bidders, up
#:      to 64), pod_activity, pod_positions, pod_triggers (these three need account), pod_receipts
#:      (account or tx_hashes), newHeads. Market channels take orderbook_ids (the "id" in pod markets).
#:   4. Numbers are 10^18-scaled, hex or decimal; times are microseconds. Pod sends 0 for a price it
#:      does not have.
#:   5. Market, positions and triggers may send the same round twice, or an older one late: keep the
#:      newest timestamp per market or account and drop the rest.
#:   6. When the connection drops, reconnect and subscribe with since = the last round received. When
#:      pod closes a stream itself, the notification carries error.data.resume_since (and
#:      resume_since_book on pod_orders_v2): subscribe again with them.

source "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
REG="$POD_HOME/live"
POD_WS="${POD_TEST_WS:-$STAGING_WS}"

CHANNELS="market book bars orders positions triggers activity receipts rounds"

# --- list and stop --------------------------------------------------------------------------------------------

alive() { kill -0 "$1" 2>/dev/null; }

listeners() {   # prints the live registry as a JSON array, dropping entries whose process is gone
  local f pid all='[]'
  mkdir -p "$REG"
  for f in "$REG"/*.json; do
    [ -f "$f" ] || continue
    pid=$(jq -r '.pid // empty' "$f" 2>/dev/null || true)
    if [ -n "$pid" ] && alive "$pid"; then all=$(echo "$all" | jq --slurpfile e "$f" '. + $e')
    else rm -f "$f"; fi
  done
  echo "$all"
}

case "${1:-}" in
  list)
    jq -n --argjson l "$(listeners)" '{ok: true, count: ($l | length), listeners: $l}'
    exit 0 ;;
  stop)
    target="${2:-}"
    [ -n "$target" ] || fail live "Name the listener to stop, or all." "pod live list shows the running ones."
    all=$(listeners)
    if [ "$target" = all ]; then ids=$(echo "$all" | jq -r '.[].id')
    else
      echo "$all" | jq -e --arg id "$target" 'any(.[]; .id == $id)' >/dev/null || fail live "No running listener '$target'." "pod live list shows the running ones."
      ids="$target"
    fi
    stopped='[]'
    for id in $ids; do
      pid=$(echo "$all" | jq -r --arg id "$id" '.[] | select(.id == $id) | .pid')
      kill -TERM "$pid" 2>/dev/null || true
      for _ in 1 2 3 4 5 6 7 8 9 10; do alive "$pid" || break; sleep 0.2; done
      alive "$pid" && kill -KILL "$pid" 2>/dev/null || true
      rm -f "$REG/$id.json"
      stopped=$(echo "$stopped" | jq --arg id "$id" '. + [$id]')
    done
    jq -n --argjson s "$stopped" '{ok: true, stopped: $s}'
    exit 0 ;;
esac

# --- arguments ------------------------------------------------------------------------------------------------

channel="${1:-}"
[ -n "$channel" ] || fail_usage live "Name a channel." "Channels: $CHANNELS. Or: list, stop. See pod live --help."
case " $CHANNELS " in *" $channel "*) ;; *) fail_usage live "Unknown channel '$channel'." "Channels: $CHANNELS. Or: list, stop. See pod live --help." ;; esac
shift

words=(); until='[]'; every=""; for_s=""; mfilter=""; order=""; depth=1; spot=false; raw=false; txs='[]'
while [ $# -gt 0 ]; do
  case "$1" in
    --until) [ -n "${2:-}" ] || fail live "--until needs a condition, e.g. \"mark < 140\"."
             until=$(echo "$until" | jq --arg c "$2" '. + [$c]'); shift 2 ;;
    --every) every="${2:-}"; shift 2 || fail live "--every needs a time, e.g. 30s, or 0." ;;
    --for) for_s="${2:-}"; shift 2 || fail live "--for needs a time, e.g. 2h." ;;
    --market) mfilter="${2:-}"; shift 2 || fail live "--market needs a market name." ;;
    --order) order="${2:-}"; shift 2 || fail live "--order needs an order id." ;;
    --tx) echo "${2:-}" | grep -Eq '^0x[0-9a-fA-F]{64}$' || fail live "--tx needs a transaction hash (0x and 64 hex characters)."
          txs=$(echo "$txs" | jq --arg t "$2" '. + [$t]'); shift 2 ;;
    --depth) depth="${2:-}"; shift 2 || fail live "--depth needs a number." ;;
    --spot) spot=true; shift ;;
    --raw) raw=true; shift ;;
    -*) fail_usage live "Unknown option $1." "See pod live --help. Options: --until, --every, --for, --market, --order, --tx, --depth, --spot, --raw." ;;
    *) words+=("$1"); shift ;;
  esac
done

every_s=""
if [ -n "$every" ]; then
  if [ "$every" = 0 ]; then every_s=0
  else every_s=$(duration_s "$every") || fail live "'$every' is not a time such as 5s, 30s or 1m (or 0 for every update)."; fi
fi
if [ -n "$for_s" ]; then
  for_in="$for_s"
  for_s=$(duration_s "$for_s") || fail live "'$for_in' is not a time such as 30m, 2h or 1d."
  { [ "$for_s" -ge 1 ] && [ "$for_s" -le 2592000 ]; } || fail live "--for must be from 1s to 30d." "Leave it out to run until stopped or the session ends."
fi
case "$depth" in ''|*[!0-9]*) fail live "--depth must be a whole number from 1 to 50." ;; esac
{ [ "$depth" -ge 1 ] && [ "$depth" -le 50 ]; } || fail live "--depth must be a whole number from 1 to 50."
[ "$depth" = 1 ] || [ "$channel" = book ] || fail live "--depth is for the book channel."
[ -z "$order" ] || case "$channel" in orders|activity) ;; *) fail live "--order is for the orders and activity channels." ;; esac
[ -z "$order" ] || echo "$order" | grep -Eq '^0x[0-9a-fA-F]{64}$' || fail live "--order needs an order id (0x and 64 hex characters)." "pod account orders lists them."
[ "$txs" = '[]' ] || [ "$channel" = receipts ] || fail live "--tx is for the receipts channel."
[ -z "$mfilter" ] || case "$channel" in orders|positions|triggers|activity) ;; *) fail live "--market is for the orders, positions, triggers and activity channels; name markets directly for $channel." ;; esac

# Node 22 or later has a WebSocket built in; nothing else is installed.
command -v node >/dev/null 2>&1 || fail live "Live updates need Node.js 22 or later, which is not installed." "brew install node"
node_major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
[ "$node_major" -ge 22 ] 2>/dev/null || fail live "Live updates need Node.js 22 or later; this is $(node -v 2>/dev/null)." "brew upgrade node"

# --- markets and accounts --------------------------------------------------------------------------------------

T=$(mktemp -d "${TMPDIR:-/tmp}/pod-live.XXXXXX")
trap 'rm -rf "$T"' EXIT
fetch_to live /clob/markets "$T/markets"
fetch_to live /clob/status "$T/status"

resolve() {   # resolve QUERY: the market's id, or fail
  local m
  m=$(jq -r --arg q "$1" --argjson s "$spot" -L "$HERE" 'include "pod"; find_market($q; $s) | .id // empty' "$T/markets")
  [ -n "$m" ] || fail live "No market called '$1'." "Name it by its ticker (e.g. NVDA), add 'spot' for the spot market, or search with pod markets list NAME."
  echo "$m"
}

market_ids='[]'; accounts='[]'; what='[]'; filter_market=""
case "$channel" in
  market|book|bars)
    [ ${#words[@]} -gt 0 ] || fail live "Name at least one market, e.g. pod live $channel NVDA."
    for w in "${words[@]}"; do
      id=$(resolve "$w") || { echo "$id"; exit 1; }
      market_ids=$(echo "$market_ids" | jq --arg id "$id" 'if index($id) then . else . + [$id] end')
    done ;;
  rounds)
    [ ${#words[@]} -eq 0 ] || fail live "rounds takes no market or address." ;;
  *)
    for w in "${words[@]+"${words[@]}"}"; do
      echo "$w" | grep -Eq '^0[xX][0-9a-fA-F]{40}$' || fail live "'$w' is not an account address (0x and 40 hex characters)."
      accounts=$(echo "$accounts" | jq --arg a "$(echo "$w" | tr 'A-F' 'a-f')" 'if index($a) then . else . + [$a] end')
    done
    if [ "$accounts" = '[]' ] && { [ "$channel" != receipts ] || [ "$txs" = '[]' ]; }; then
      profile_exists || fail live "No address was named and no wallet is connected." "Name an address, or connect a wallet with pod setup."
      accounts=$(jq -n --arg a "$(profile_get '.wallet.address' | tr 'A-F' 'a-f')" '[$a]')
    fi
    n=$(echo "$accounts" | jq length)
    case "$channel" in
      orders) [ "$n" -le 64 ] || fail live "The orders channel follows at most 64 accounts at once." ;;
      *) [ "$n" -le 1 ] || fail live "The $channel channel follows one account at a time." "Start one listener per account, or use the orders channel for several." ;;
    esac
    if [ -n "$mfilter" ]; then
      filter_market=$(resolve "$mfilter") || { echo "$filter_market"; exit 1; }
    fi ;;
esac

# What the first line names: market names, or short addresses.
what=$(jq -n -L "$HERE" --slurpfile m "$T/markets" --argjson ids "$market_ids" --argjson acc "$accounts" \
  --argjson txs "$txs" --arg fm "$filter_market" --arg ch "$channel" 'include "pod";
  ($m[0] | market_map) as $mm
  | if $ch == "rounds" then ["every auction round"]
    elif ($ids | length) > 0 then [$ids[] | $mm[.] // .]
    else [$acc[] | .[0:6] + "…" + .[-4:]] + [$txs[] | "tx " + .[0:10] + "…"]
         + (if $fm == "" then [] else ["only " + ($mm[$fm] // $fm)] end) end')

cfg=$(jq -n -L "$HERE" --slurpfile m "$T/markets" --slurpfile st "$T/status" \
  --arg channel "$channel" --argjson ids "$market_ids" --argjson acc "$accounts" --argjson what "$what" \
  --argjson until "$until" --arg every "$every_s" --arg for "$for_s" --arg fm "$filter_market" --arg order "$order" \
  --argjson depth "$depth" --argjson raw "$raw" --argjson txs "$txs" --arg ws "$POD_WS" --arg home "$POD_HOME" '
  {channel: $channel, market_ids: $ids, accounts: $acc, what: $what, until: $until,
   every_s: (if $every == "" then null else ($every | tonumber) end),
   for_s: (if $for == "" then null else ($for | tonumber) end),
   filter_market: (if $fm == "" then null else $fm end), order: (if $order == "" then null else $order end),
   depth: $depth, raw: $raw, txs: $txs, ws_url: $ws, home: $home, now_us: $st[0].solution_now,
   markets: ($m[0] | map({key: .id, value: {label: (.base_token_symbol + " " + .market_type), type: .market_type}}) | from_entries)}')

rm -rf "$T"; trap - EXIT
exec node "$HERE/live.mjs" "$cfg"
