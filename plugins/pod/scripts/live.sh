#!/usr/bin/env bash
# Follow pod live: prices, the book, bars, an account's orders, positions, triggers and activity,
# transaction receipts, or each auction round. Prints one JSON line per update until a condition
# holds, the time is up, it is stopped, or the session ends. Read-only; sends nothing.
#
# Usage:
#   live.sh CHANNEL [MARKET... | ADDRESS] [--until "FIELD OP VALUE"]... [--every 30s] [--for 2h] [options]
#   live.sh list                 the listeners running on this machine
#   live.sh stop ID|all          stop one listener, or all of them
#
# Channels:
#   market MARKET...     price, 24-hour numbers, funding, open interest      (every 30s by default)
#   book MARKET...       best bid and ask, spread; --depth N for N levels      (every 30s)
#   bars MARKET...       one price bar per --every window, built from each round (every 30s)
#   orders [ADDRESS...]  order events: new, filled, cancelled, expired; up to 64 accounts (every change)
#   positions [ADDRESS]  account value and positions when they change             (every change)
#   triggers [ADDRESS]   armed stop-losses and take-profits when they change      (every change)
#   activity [ADDRESS]   everything that happens on the account                   (every change)
#   receipts [ADDRESS] [--tx HASH]...  transaction outcomes; with --tx it ends when all have arrived
#   rounds               each auction round, counted per --every window          (every 30s)
#
#   ADDRESS defaults to the connected wallet.
#   --until "mark < 140"   stop and report when a condition holds; repeat for "any of these"
#   --every 30s | 0        at most one line per window and only when something changed; 0 = every update
#   --for 2h               stop after this long (default: until stopped or the session ends)
#   --market NAME          account channels: only this market      --order ID  orders, activity: one order
#   --depth N              book: levels per side (1 to 50)          --spot      pick the spot market
#   --raw                  pod's messages unchanged
#
# Needs Node.js 22 or later (its built-in WebSocket). Spec: specs/07-live.md.

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
    [ -n "$target" ] || fail live "Name the listener to stop, or all." "live.sh list shows the running ones."
    all=$(listeners)
    if [ "$target" = all ]; then ids=$(echo "$all" | jq -r '.[].id')
    else
      echo "$all" | jq -e --arg id "$target" 'any(.[]; .id == $id)' >/dev/null || fail live "No running listener '$target'." "live.sh list shows the running ones."
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
[ -n "$channel" ] || fail live "Name a channel." "Channels: $CHANNELS. Or: list, stop."
case " $CHANNELS " in *" $channel "*) ;; *) fail live "Unknown channel '$channel'." "Channels: $CHANNELS. Or: list, stop." ;; esac
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
    -*) fail live "Unknown option $1." "Options: --until, --every, --for, --market, --order, --tx, --depth, --spot, --raw." ;;
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
[ -z "$order" ] || echo "$order" | grep -Eq '^0x[0-9a-fA-F]{64}$' || fail live "--order needs an order id (0x and 64 hex characters)." "account.sh orders lists them."
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
  [ -n "$m" ] || fail live "No market called '$1'." "Name it by its ticker (e.g. NVDA), add 'spot' for the spot market, or search with markets.sh list."
  echo "$m"
}

market_ids='[]'; accounts='[]'; what='[]'; filter_market=""
case "$channel" in
  market|book|bars)
    [ ${#words[@]} -gt 0 ] || fail live "Name at least one market, e.g. live.sh $channel NVDA."
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
      profile_exists || fail live "No address was named and no wallet is connected." "Name an address, or connect a wallet with /pod:setup."
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
