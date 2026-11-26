#!/usr/bin/env bash
# What is traded on pod, at what price, how deep the book is and how prices moved. Read-only.
#
# Usage:
#   markets.sh [VIEW] [MARKET | QUERY] [options]
#
#   list [QUERY]   every active market with its price (default view); QUERY narrows by name
#                  --type perp|spot  --sort volume|change|name|open-interest|funding  --all  --limit N
#   movers         biggest 24-hour rises and falls, and the most traded  --limit N (per group, default 5)
#   market MARKET  one market: price, 24-hour numbers, funding, spread, and its trading rules
#   book MARKET    the order book  --depth N (levels per side, default 10)
#                  --size N [--side buy|sell]: what a market order of that size would clear at now
#   bars MARKET    price bars  --resolution 1m|5m|15m|30m|1h|4h|1d|1w|1M (default 1h)
#                  --limit N (1 to 1000, default 50)  --since WHEN
#   rounds MARKET  per-round history: traded price, mark, oracle, volume, funding, open interest
#                  --limit N (1 to 1000, default 20)  --since WHEN
#
#   MARKET   loose: NVDA, nvidia, "NVDA perp", "NVDA spot", or the 0x market id. Perps win unless
#            --spot or "spot" is given.
#   --raw    pod's answers unchanged
#
# The headline price is the mark price on perps and the last traded price on spot. Fields the plugin
# works out itself are named in "computed". Spec: specs/06-market-data.md.

source "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"

VIEWS="list movers market book bars rounds"
RESOLUTIONS="1m 5m 15m 30m 1h 4h 1d 1w 1M"
SORTS="volume change name open-interest funding"

view=""; words=""; mtype=""; sort="volume"; all=false; limit=""; depth=10; size=""; side=""
resolution="1h"; since=""; spot=false; raw=false
while [ $# -gt 0 ]; do
  case "$1" in
    --type) mtype="${2:-}"; shift 2 || fail markets "--type needs perp or spot." ;;
    --sort) sort="${2:-}"; shift 2 || fail markets "--sort needs a value." ;;
    --all) all=true; shift ;;
    --limit) limit="${2:-}"; shift 2 || fail markets "--limit needs a number." ;;
    --depth) depth="${2:-}"; shift 2 || fail markets "--depth needs a number." ;;
    --size) size="${2:-}"; shift 2 || fail markets "--size needs an amount, e.g. 10." ;;
    --side) side="${2:-}"; shift 2 || fail markets "--side needs buy or sell." ;;
    --resolution) resolution="${2:-}"; shift 2 || fail markets "--resolution needs a bar size, e.g. 1h." ;;
    --since) since="${2:-}"; shift 2 || fail markets "--since needs a value, e.g. 7d." ;;
    --spot) spot=true; shift ;;
    --raw) raw=true; shift ;;
    -*) fail markets "Unknown option $1." "Options: --type, --sort, --all, --limit, --depth, --size, --side, --resolution, --since, --spot, --raw." ;;
    *) if [ -z "$view" ] && [ -z "$words" ] && case " $VIEWS " in *" $1 "*) true ;; *) false ;; esac; then view="$1"
       else words="${words:+$words }$1"; fi
       shift ;;
  esac
done
[ -n "$view" ] || view="list"

# --- check the options --------------------------------------------------------------------------------

whole() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
case "$view" in
  list)   [ -n "$limit" ] || limit=100; max=100 ;;
  movers) [ -n "$limit" ] || limit=5; max=20 ;;
  bars)   [ -n "$limit" ] || limit=50; max=1000 ;;
  rounds) [ -n "$limit" ] || limit=20; max=1000 ;;
  *)      [ -z "$limit" ] || fail markets "--limit is for list, movers, bars and rounds."; limit=1; max=1 ;;
esac
{ whole "$limit" && [ "$limit" -ge 1 ] && [ "$limit" -le "$max" ]; } || fail markets "--limit must be a whole number from 1 to $max for $view."
case "$view" in
  market|book|bars|rounds) [ -n "$words" ] || fail markets "Name a market, e.g. markets.sh $view NVDA." ;;
  movers) [ -z "$words" ] || fail markets "movers takes no market name." "Use markets.sh market NAME for one market." ;;
esac
[ -z "$mtype" ] || case "$mtype" in perp|spot) ;; *) fail markets "--type must be perp or spot." ;; esac
case " $SORTS " in *" $sort "*) ;; *) fail markets "Unknown sort '$sort'." "Sorts: $SORTS." ;; esac
case " $RESOLUTIONS " in *" $resolution "*) ;; *) fail markets "Unknown bar size '$resolution'." "Bar sizes: $RESOLUTIONS." ;; esac
{ whole "$depth" && [ "$depth" -ge 1 ] && [ "$depth" -le 500 ]; } || fail markets "--depth must be a whole number from 1 to 500."
if [ -n "$size" ]; then
  [ "$view" = book ] || fail markets "--size is for the book view."
  echo "$size" | grep -Eq '^[0-9]+(\.[0-9]+)?$' && [ "$(echo "$size > 0" | bc)" = 1 ] || fail markets "--size must be a positive number, e.g. 10 or 0.5."
fi
[ -z "$side" ] || case "$side" in buy|sell) [ -n "$size" ] || fail markets "--side goes with --size." ;; *) fail markets "--side must be buy or sell." ;; esac
SINCE_US=""
if [ -n "$since" ]; then
  case "$view" in bars|rounds) ;; *) fail markets "--since is for bars and rounds." ;; esac
  SINCE_US=$(since_us "$since") || fail markets "'$since' is not a time I understand." "Use 30m, 24h, 7d, 2026-11-01 or 2026-11-01T12:00:00Z."
fi

T=$(mktemp -d "${TMPDIR:-/tmp}/pod-markets.XXXXXX")
trap 'rm -rf "$T"' EXIT
fetch() { fetch_to markets "$1" "$2"; }
fetch_book() {   # fetch_book PATH FILE: like fetch, but a market that has never cleared (404) gets {}
  local code
  code=$(curl -sS --max-time 20 --retry 1 --retry-delay 1 -o "$2" -w '%{http_code}' "$POD_REST$1" 2>/dev/null) || code=000
  [ "$code" = 404 ] && { echo '{}' > "$2"; return 0; }
  [ "$code" = 200 ] && return 0
  fetch "$1" "$2"   # any other answer is reported the usual way
}
echo '[]' > "$T/pages"; echo '[]' > "$T/items"
keep_page() {   # keep_page FILE ITEMS_JQ
  jq -s '.[0] + [.[1]]' "$T/pages" "$1" > "$T/p.new" && mv "$T/p.new" "$T/pages"
  jq -s ".[0] + (.[1] | $2)" "$T/items" "$1" > "$T/i.new" && mv "$T/i.new" "$T/items"
}
count() { jq length "$T/items"; }

fetch /clob/markets "$T/markets"

# --- which market ------------------------------------------------------------------------------------------

MID=""
case "$view" in
  market|book|bars|rounds)
    jq --arg q "$words" --argjson s "$spot" -L "$HERE" 'include "pod"; find_market($q; $s)' "$T/markets" > "$T/market"
    [ "$(cat "$T/market")" != "null" ] || fail markets "No market called '$words'." \
      "Name it by its ticker (e.g. NVDA), add 'spot' for the spot market, or search with markets.sh list $words."
    MID=$(jq -r .id "$T/market") ;;
esac

# --- read ------------------------------------------------------------------------------------------------------

more=false
case "$view" in
  list|movers|market)
    fetch /clob/markets/stats "$T/stats"; keep_page "$T/stats" '[]'
    [ "$view" = market ] && { fetch_book "/clob/orderbook/$MID?depth=1" "$T/book"; keep_page "$T/book" '[]'; } ;;
  book)
    if [ -n "$size" ]; then
      fetch_book "/clob/orderbook/$MID" "$T/book"
      fetch /clob/markets/stats "$T/stats"   # the estimate's band starts from the mark or last price
    else
      fetch_book "/clob/orderbook/$MID?depth=$depth" "$T/book"; echo '{"markets":[]}' > "$T/stats"
    fi
    [ "$(cat "$T/book")" != '{}' ] || fail markets "$(jq -r '.base_token_symbol + " " + .market_type' "$T/market") has no order book yet: it has never traded (status $(jq -r .status "$T/market"))." \
      "Pod builds the book when the market first clears. markets.sh market NAME shows its rules."
    keep_page "$T/book" '[]' ;;
  bars)
    # Newest first, at most 500 a page. The bar still forming is dropped after pod applies `limit`,
    # so a page reaching the present holds one bar fewer than asked: ask for one more.
    to=""
    while [ "$(count)" -lt "$limit" ]; do
      p=$(( limit - $(count) + 1 )); [ "$p" -gt 500 ] && p=500
      fetch "/clob/candles/$MID?resolution=$resolution&limit=$p${SINCE_US:+&from=$(( SINCE_US / 1000000 ))}${to:+&to=$to}" "$T/resp"
      keep_page "$T/resp" '.candles // []'
      got=$(jq '.candles // [] | length' "$T/resp")
      [ "$got" -lt $(( p - 1 )) ] && break
      [ "$got" -eq 0 ] && break
      to=$(( $(jq '.range.from_us' "$T/resp") / 1000000 ))
      [ "$(count)" -ge "$limit" ] && more=true
    done ;;
  rounds)
    until=""
    while [ "$(count)" -lt "$limit" ]; do
      p=$(( limit - $(count) )); [ "$p" -gt 200 ] && p=200
      fetch "/clob/solutions?orderbook=$MID&limit=$p${SINCE_US:+&since_us=$SINCE_US}${until:+&until_us=$until}" "$T/resp"
      keep_page "$T/resp" '.solutions // []'
      got=$(jq '.solutions // [] | length' "$T/resp")
      [ "$got" -lt "$p" ] && break
      until=$(jq '[.solutions[].timestamp] | min' "$T/resp")
      [ "$(count)" -ge "$limit" ] && more=true
    done ;;
esac
if [ "$(count)" -gt "$limit" ]; then jq ".[0:$limit]" "$T/items" > "$T/i.new" && mv "$T/i.new" "$T/items"; more=true; fi

base() {
  jq -n --arg view "$view" --arg at "$(now_iso)" --slurpfile mk <( [ -f "$T/market" ] && cat "$T/market" || echo null ) '
    {ok: true, view: $view, as_of: $at}
    + (if $mk[0] == null then {} else {market: ($mk[0].base_token_symbol + " " + $mk[0].market_type), market_id: $mk[0].id} end)'
}

if $raw; then
  base | jq --slurpfile p "$T/pages" '. + {raw: $p[0]}'
  exit 0
fi

# --- shape -------------------------------------------------------------------------------------------------------

JQ_DEFS='
include "pod";
def nonull: with_entries(select(.value != null and .value != [] and .value != ""));
def num: if . == null then null else tonumber end;
def mlabel: .base_token_symbol + " " + .market_type;
def opt_amount: if . == null then null else amount end;
# A price pod sends as 0 when it has none (e.g. a halted market) is no price at all.
def opt_price: if . == null then null else price_or_null end;
# Pod sends the 24-hour change in basis points: 534 is +5.34%.
def change_pct: if . == null then null else (. / 100 | fixed(2)) end;
def funding($m; $st):
  ($st.funding_rate | if . == null then null else (amount | tonumber) end) as $r
  | ($m.funding_window_us // 28800000000) as $w
  | if $r == null then null else
      {rate_pct: ($r * 100 | fixed(6)), every_hours: ($w / 3600000000),
       per_year_pct: ($r * 100 * (365 * 24 * 3600000000 / $w) | fixed(4)),
       who_pays: (if $r > 0 then "longs pay shorts" elif $r < 0 then "shorts pay longs" else "nobody" end)}
    end;
# The headline price: the mark price on perps (what positions are valued and liquidated at), the
# last traded price on spot (which has no mark). trade.sh starts market orders from the same price.
def live($m; $st):
  ($m.market_type == "perp") as $perp
  | ($st.last_clearing_price | opt_price) as $last
  | ($st.mark_price | opt_price) as $mark
  | ($st.oracle_price | opt_price) as $oracle
  | (if $perp and $mark != null then {price: $mark, price_kind: "mark"}
     else {price: $last, price_kind: (if $last == null then null else "last traded" end)} end)
  + {last_price: $last, change_24h_pct: ($st.price_change_24h | change_pct),
     high_24h: ($st.high_24h | opt_price), low_24h: ($st.low_24h | opt_price),
     volume_24h_usd: ($st.volume_24h | opt_amount)}
  + (if $perp then
       {mark_price: $mark, oracle_price: $oracle,
        oracle_stale: (if $st.internal then true else null end),
        funding: funding($m; $st), open_interest_usd: ($st.open_interest | opt_amount),
        mark_vs_oracle_pct: (if $mark == null or $oracle == null or ($oracle | tonumber) == 0 then null
                             else ((($mark | tonumber) - ($oracle | tonumber)) / ($oracle | tonumber) * 100 | fixed(4)) end)}
     else {} end);
def rules:
  (.market_type == "perp") as $perp
  | {maker_fee_pct: (.maker_fee | tonumber * 100 | fixed(6)), taker_fee_pct: (.taker_fee | tonumber * 100 | fixed(6)),
     price_step: (.tick_precision | amount), size_step: (.lot_size | amount),
     min_order_value_usd: (.min_notional | amount),
     max_leverage: (if $perp then .max_leverage else null end),
     initial_margin_pct: (if $perp then (.initial_margin | amount | tonumber * 100 | fixed(4)) else null end),
     auction_every_seconds: (.auction_interval_us / 1000000),
     goes_live: (.live_at_us | us_time), halts_at: (.disable_at_us | us_time),
     settlement_price: (.settlement_price | opt_amount)} | nonull;
# Pod keys book levels by price, lowest first, as strings; sort on the number.
def levels($k): (.[$k] // {}) | to_entries | map({price: (.key | amount), size: (.value.volume | amount)})
  | sort_by(.price | tonumber);
def running: reduce .[] as $l ({acc: [], s: 0, v: 0};
  .s += ($l.size | tonumber) | .v += (($l.size | tonumber) * ($l.price | tonumber))
  | .acc += [$l + {total_size: (.s | fixed(8)), total_value_usd: (.v | fixed(4))}]) | .acc;
def top($b):
  ($b | levels("buys") | last) as $bid | ($b | levels("sells") | first) as $ask
  | if $bid == null or $ask == null then {best_bid: ($bid.price // null), best_ask: ($ask.price // null)} | nonull
    else ((($bid.price | tonumber) + ($ask.price | tonumber)) / 2) as $mid
      | {best_bid: $bid.price, best_ask: $ask.price, mid: ($mid | fixed(8)),
         spread: ((($ask.price | tonumber) - ($bid.price | tonumber)) | fixed(8)),
         spread_pct: ((($ask.price | tonumber) - ($bid.price | tonumber)) / $mid * 100 | fixed(4))} end;
def row($SM):
  . as $m | ($SM[$m.id] // {}) as $st | live($m; $st) as $l
  | {market: mlabel, name: .base_token_name, type: .market_type, status,
     price: $l.price, price_kind: $l.price_kind, change_24h_pct: $l.change_24h_pct,
     volume_24h_usd: $l.volume_24h_usd, funding_rate_pct: ($l.funding.rate_pct // null),
     open_interest_usd: ($l.open_interest_usd // null), id} | nonull;
'

computed='[]'
case "$view" in
  list|movers)
    jq -n -L "$HERE" --slurpfile m "$T/markets" --slurpfile s "$T/stats" \
      --arg q "$words" --arg type "$mtype" --arg sort "$sort" --argjson all "$all" --argjson limit "$limit" --arg view "$view" "$JQ_DEFS"'
      ($s[0].markets | map({key: .orderbook_id, value: .}) | from_entries) as $SM
      | ($q | ascii_downcase) as $q
      | [ $m[0][]
          | select($all or .status == "active")
          | select($type == "" or .market_type == $type)
          | select($q == "" or ([.base_token_symbol, .base_token_name, .name] | map(ascii_downcase) | any(contains($q))))
          | row($SM) ] as $rows
      | def by(f): sort_by(f | if . == null then -1e300 else tonumber end) | reverse;
        if $view == "movers" then
          [$rows[] | select(.change_24h_pct != null)] as $c
          | {rising: ([$c[] | select((.change_24h_pct | tonumber) > 0)] | by(.change_24h_pct) | .[0:$limit]),
             falling: ([$c[] | select((.change_24h_pct | tonumber) < 0)] | sort_by(.change_24h_pct | tonumber) | .[0:$limit]),
             most_traded: ([$rows[] | select((.volume_24h_usd // "0" | tonumber) > 0)] | by(.volume_24h_usd) | .[0:$limit])}
        else
          ($rows | if $sort == "name" then sort_by(.market)
                   elif $sort == "change" then by(.change_24h_pct)
                   elif $sort == "open-interest" then by(.open_interest_usd)
                   elif $sort == "funding" then by(.funding_rate_pct)
                   else by(.volume_24h_usd) end) as $sorted
          | {rows: $sorted[0:$limit], more: (($sorted | length) > $limit)}
        end' > "$T/out"
    if [ "$view" = list ]; then
      more=$(jq .more "$T/out"); jq .rows "$T/out" > "$T/data"
    else
      cp "$T/out" "$T/data"
    fi ;;
  market)
    computed='["mark_vs_oracle_pct","funding.per_year_pct","book.mid","book.spread","book.spread_pct"]'
    jq -n -L "$HERE" --slurpfile m "$T/market" --slurpfile s "$T/stats" --slurpfile b "$T/book" "$JQ_DEFS"'
      $m[0] as $M | ($s[0].markets | map(select(.orderbook_id == $M.id)) | .[0] // {}) as $st
      | live($M; $st) as $l | top($b[0]) as $t
      | def usd: if . == null then "none" else "$" + (tonumber | fixed(4)) end;   # the summary rounds; the fields stay exact
      {market: ($M | mlabel), name: $M.base_token_name, type: $M.market_type, status: $M.status}
      + $l + {book: $t, rules: ($M | rules)}
      | . + {summary: ([
          (if .price == null then "\(.market): no price yet" else "\(.market) \(.price | usd) (\(.price_kind))" end),
          (if .change_24h_pct == null then empty elif (.change_24h_pct | tonumber) == 0 then "unchanged in 24 h"
           else "\(if (.change_24h_pct | startswith("-")) then "" else "+" end)\(.change_24h_pct)% in 24 h" end),
          (if .oracle_stale then "oracle stale: derived from the book" else empty end),
          (if .funding then "funding \(.funding.rate_pct)% per \(.funding.every_hours) h, \(.funding.who_pays)" else empty end),
          (if .book.spread then "spread $\(.book.spread) (\(.book.spread_pct)%)" else "no two-sided book" end),
          (if .status != "active" then "status \(.status)" else empty end)] | join(" · "))}
      | nonull' > "$T/data" ;;
  book)
    computed='["mid","spread","spread_pct","total_size","total_value_usd"]'
    [ -n "$size" ] && computed='["mid","spread","spread_pct","total_size","total_value_usd","estimate"]'
    jq -n -L "$HERE" --slurpfile m "$T/market" --slurpfile b "$T/book" --slurpfile s "$T/stats" --argjson depth "$depth" \
      --arg size "$size" --arg side "$side" --arg band "$(setting market_band_pct)" "$JQ_DEFS"'
      $m[0] as $M | $b[0] as $B | top($B) as $t
      | (live($M; ($s[0].markets | map(select(.orderbook_id == $M.id)) | .[0] // {})).price) as $ref
      | ($B | levels("sells")) as $asks | ($B | levels("buys") | reverse) as $bids
      # Pod clears each market once per round at one price for everyone. A market order of SIZE
      # would clear at about the price of the last level it needs: the highest ask for a buy, the
      # lowest bid for a sell. Orders arriving in the same round can move it.
      | def estimate($lv; $sd):
          ($size | tonumber) as $want
          | ($lv | reduce .[] as $l ({need: $want, got: 0, at: null};
              if .need > 0 then .at = $l.price | .got += ([($l.size | tonumber), .need] | min)
                | .need -= ($l.size | tonumber) else . end)) as $w
          | ($t.mid // null) as $mid
          | if $w.at == null then {side: $sd, size: $size, enough_depth: false, note: "No resting \(if $sd == "buy" then "sells" else "buys" end): a market order would not fill now."}
            else ($w.at | tonumber) as $p | ($w.got * $p) as $val
              | {side: $sd, size: $size, clears_at_about: $w.at, enough_depth: ($w.need <= 0),
                 fills_size: (if $w.need > 0 then ($w.got | fixed(8)) else null end),
                 value_usd: ($val | fixed(4)), fee_usd: ($val * ($M.taker_fee | tonumber) | fixed(4)),
                 vs_mid_pct: (if $mid == null then null else (($p - ($mid | tonumber)) / ($mid | tonumber) * 100 | fixed(4)) end),
                 within_default_band: (if $ref == null then null
                    elif $sd == "buy" then ($p <= ($ref | tonumber) * (1 + ($band | tonumber) / 100))
                    else ($p >= ($ref | tonumber) * (1 - ($band | tonumber) / 100)) end)} | nonull
            end;
      $t + {buy_levels: $B.buys_count, sell_levels: $B.sells_count,
            last_traded_price: ($B.clearing_price | opt_price), oracle_price: ($B.oracle_price | opt_price),
            book_time: ($B.timestamp | us_time_ms),
            bids: ($bids | running | .[0:$depth]), asks: ($asks | running | .[0:$depth])}
      + (if $size == "" then {} else
           {estimate: [ (if $side != "sell" then estimate($asks; "buy") else empty end),
                        (if $side != "buy" then estimate($bids; "sell") else empty end) ],
            estimate_note: "Pod clears each round at one price for everyone: this is the price where the resting orders first cover the size. Orders arriving in the same round can move it. within_default_band says whether it lies inside the \($band)% band a market order uses by default, counted from \(if $M.market_type == "perp" then "the mark price" else "the last traded price" end) $\($ref // "?")."} end)
      | nonull' > "$T/data" ;;
  bars)
    computed='["summary"]'
    jq -L "$HERE" "$JQ_DEFS"'
      [.[] | {time: (.timestamp | us_time), open: (.open | amount), high: (.high | amount), low: (.low | amount),
              close: (.close | amount), volume: (.volume | amount), value_usd: (.quote_volume | opt_amount),
              oracle_price: (.oracle_price | price_or_null)} | nonull] as $bars
      | if $bars == [] then {bars: [], summary: null} else
          ($bars | last) as $old | ($bars | first) as $new
          | {summary: {bars: ($bars | length), first_bar: $old.time, last_bar: $new.time,
                       open: $old.open, close: $new.close,
                       change_pct: (if ($old.open | tonumber) == 0 then null
                                    else ((($new.close | tonumber) - ($old.open | tonumber)) / ($old.open | tonumber) * 100 | fixed(4)) end),
                       high: ($bars | max_by(.high | tonumber) | .high), low: ($bars | min_by(.low | tonumber) | .low),
                       volume: ([$bars[].volume | tonumber] | add | fixed(8)),
                       value_usd: ([$bars[].value_usd // "0" | tonumber] | add | fixed(4))} | nonull,
             bars: $bars} end' "$T/items" > "$T/data" ;;
  rounds)
    jq -L "$HERE" --slurpfile m "$T/market" "$JQ_DEFS"'
      [.[] | {time: (.timestamp | us_time_ms), traded_price: (.clearing_price | price_or_null),
              mark_price: (.mark_price | price_or_null), oracle_price: (.oracle_price | price_or_null),
              volume: (.volume | opt_amount),
              funding_rate_pct: (if .funding_rate == null then null else (.funding_rate | amount | tonumber * 100 | fixed(6)) end),
              open_interest_usd: (.open_interest | opt_amount)} | nonull]' "$T/items" > "$T/data" ;;
esac

case "$view" in list|rounds) list=true ;; bars) list=bars ;; *) list=false ;; esac
base | jq --slurpfile d "$T/data" --argjson more "$more" --arg list "$list" --argjson computed "$computed" \
  --arg resolution "$resolution" --arg since "$since" --arg sus "$SINCE_US" -L "$HERE" 'include "pod";
  . + (if .view == "bars" then {resolution: $resolution} else {} end)
    + (if $since == "" then {} else {since: ($sus | us_time)} end)
    + (if $list == "true" then {count: ($d[0] | length), more: $more}
       elif $list == "bars" then {count: ($d[0].bars | length), more: $more} else {} end)
    + (if $computed == [] then {} else {computed: $computed} end)
    + {data: $d[0]}'
