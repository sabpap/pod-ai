# Shared helpers for the pod command's scripts. Sourced, never run directly.
# Works with the macOS system bash (3.2): no associative arrays, no ${x,,}.
#
# Every script prints exactly one JSON object on stdout:
#   success: {"ok": true, ...}
#   failure: {"ok": false, "step": "...", "error": "...", "fix": "..."}   (exit code 1)
#   usage:   the same shape with exit code 2 (unknown command or option)

set -euo pipefail

# The scripts run only through the pod command (cli/pod), which sets POD_CLI=1. This keeps one
# entry point, one manual and one place for the approval hook to watch.
if [ "${POD_CLI:-}" != 1 ]; then
  printf '%s\n' '{"ok": false, "step": "usage", "error": "This script runs only through the pod command.", "fix": "Run pod help to see the commands."}'
  exit 2
fi

# --- where things live ---------------------------------------------------------------------------

POD_HOME="${POD_PLUGIN_HOME:-$HOME/.config/pod-plugin}"
PROFILE="$POD_HOME/profile.json"
KEYSTORE_DIR="${POD_KEYSTORE_DIR:-$HOME/.foundry/keystores}"
KEYCHAIN_SERVICE="foundry-keystore"

# --- the only network pod may send on (decision S9) ----------------------------------------------

STAGING_NAME="staging"
STAGING_CHAIN_ID=129302
STAGING_REST="https://staging-rpc.podtestnet.dev/v1"
STAGING_RPC="https://staging-rpc.podtestnet.dev"
STAGING_WS="wss://staging-rpc.podtestnet.dev"

# Tests point these at a fake server; nothing else may change them.
POD_REST="${POD_TEST_REST:-$STAGING_REST}"
POD_RPC="${POD_TEST_RPC:-$STAGING_RPC}"

ORDERBOOK="0x50d0000000000000000000000000000000000002"   # pod's built-in order book contract
SUBMIT_ORDER="submitOrder(bytes32,int256,uint256,uint8,uint128,uint128,uint8)"
CANCEL="cancel(bytes32,bytes32,uint128)"
FLAG_POST_ONLY=4
AUCTION_US=500000

# --- output ----------------------------------------------------------------------------------------

# fail STEP ERROR [FIX]: print the failure object and exit 1.
fail() {
  jq -n --arg step "$1" --arg error "$2" --arg fix "${3:-}" \
    '{ok: false, step: $step, error: $error} + (if $fix == "" then {} else {fix: $fix} end)'
  exit 1
}

# fail_usage STEP ERROR [FIX]: like fail, for an unknown command or option: exit code 2.
fail_usage() {
  jq -n --arg step "$1" --arg error "$2" --arg fix "${3:-}" \
    '{ok: false, step: $step, error: $error} + (if $fix == "" then {} else {fix: $fix} end)'
  exit 2
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_us() { echo $(( $(date +%s) * 1000000 )); }

# --- pod API ----------------------------------------------------------------------------------------

# rest PATH: GET a REST route and print the body. Returns non-zero on network or HTTP errors.
rest() {
  curl -sS --fail --max-time 15 "$POD_REST$1"
}

# fetch_to STEP PATH FILE: GET a REST route into FILE, tried twice. On failure it stops the script
# with pod's own reason (e.g. 503 "clob indexer unavailable"), and never writes the error into FILE
# as if it were data.
fetch_to() {
  local step="$1" path="$2" file="$3" code why route="${2%%\?*}"
  code=$(curl -sS --max-time 20 --retry 1 --retry-delay 1 -o "$file" -w '%{http_code}' "$POD_REST$path" 2>/dev/null) || code=000
  [ "$code" = 200 ] && return 0
  if [ "$code" = 000 ]; then
    fail "$step" "Pod did not answer $route in time." "Try again in a moment, or ask for fewer entries with --limit or --since."
  fi
  why=$(head -c 200 "$file" 2>/dev/null | tr -d '\n' || true)
  fail "$step" "Pod answered $route with an error ($code${why:+: $why})." "This is on pod's side. Try again in a moment."
}

# rpc METHOD PARAMS_JSON: call JSON-RPC and print the whole response object.
rpc() {
  curl -sS --fail --max-time 15 -X POST "$POD_RPC" -H 'content-type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}"
}

# rpc_result METHOD PARAMS_JSON: print .result, or fail with pod's error message.
rpc_result() {
  local out
  out=$(rpc "$1" "$2") || return 1
  if [ "$(echo "$out" | jq 'has("error")')" = "true" ]; then
    echo "$out" | jq -c '.error' >&2
    return 2
  fi
  echo "$out" | jq -c '.result'
}

# require_staging: refuse to go on unless the RPC answers with pod staging's chain id.
require_staging() {
  local hex id
  hex=$(rpc_result eth_chainId '[]' 2>/dev/null | jq -r '.') || fail network "Pod does not answer at $POD_RPC." "Try again later."
  id=$(printf '%d' "$hex")
  [ "$id" = "$STAGING_CHAIN_ID" ] || fail network \
    "The network answered with chain id $id, not pod staging ($STAGING_CHAIN_ID). Nothing was sent." \
    "pod only sends on pod staging."
}

# --- numbers -----------------------------------------------------------------------------------------
# Pod scales amounts and prices by 10^18 and mixes hex and decimal strings. Bash integers stop at
# 9.2 * 10^18, so big numbers go through bc.

# to_dec VALUE: a pod number (hex "0x.." or decimal string) as a decimal integer string.
to_dec() {
  case "$1" in
    0x*|0X*) local h; h=$(echo "${1#0[xX]}" | tr 'a-f' 'A-F'); echo "ibase=16; $h" | bc | tr -d '\\\n' ;;
    *) echo "$1" ;;
  esac
}

# human WEI: a 10^18-scaled integer as a plain decimal, e.g. 150930000000000000000 -> 150.93
human() {
  echo "scale=18; $(to_dec "$1") / 10^18" | bc | sed -e 's/^\./0./' -e 's/^-\./-0./' -e '/\./ s/0*$//' -e 's/\.$//'
}

# money DECIMAL: a dollar amount for a one-line summary: at most 4 decimals, no trailing zeros.
# 99.99666537 -> 99.9967, 100.000 -> 100. Two decimals would hide the small moves a test trade makes.
money() {
  LC_ALL=C printf '%.4f' "$1" | sed -e '/\./ s/0*$//' -e 's/\.$//' -e 's/^-0$/0/'
}

# to_wei DECIMAL: a plain decimal ("151.034", "0.01", "5") as pod's 10^18-scaled integer, exactly.
# Returns 1 for anything else, or for more than 18 decimals.
to_wei() {
  local v="$1" int frac=""
  echo "$v" | grep -Eq '^[0-9]+(\.[0-9]+)?$' || return 1
  int=${v%%.*}
  case "$v" in *.*) frac=${v#*.} ;; esac
  [ ${#frac} -le 18 ] || return 1
  frac=$(printf '%-18s' "$frac" | tr ' ' 0)
  echo "$int$frac" | sed -e 's/^0*//' -e 's/^$/0/'
}

# duration_s WHEN: 30s, 10m, 1h, 7d as seconds. Returns 1 for anything else.
duration_s() {
  local n="${1%?}" u="${1#"${1%?}"}"
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  case "$u" in s) echo "$n" ;; m) echo $(( n * 60 )) ;; h) echo $(( n * 3600 )) ;; d) echo $(( n * 86400 )) ;; *) return 1 ;; esac
}

# setting NAME: a profile setting, or its default (trading decisions TR1, TR3, TR6).
setting() {
  local d
  case "$1" in approval) d=ask ;; market_band_pct) d=2 ;; default_ttl) d=1d ;; *) return 1 ;; esac
  if profile_exists; then jq -r --arg k "$1" --arg d "$d" '.settings[$k] // $d' "$PROFILE"; else echo "$d"; fi
}

# settings_json: the trading settings with defaults filled in, and the same in plain words.
settings_json() {
  jq -n --arg a "$(setting approval)" --arg b "$(setting market_band_pct)" --arg t "$(setting default_ttl)" '
    def words: capture("^(?<n>[0-9]+)(?<u>[smhd])$") as $c
      | ({s: "second", m: "minute", h: "hour", d: "day"}[$c.u]) as $w
      | "\($c.n) \($w)\(if $c.n == "1" then "" else "s" end)";
    {approval: $a, market_band_pct: ($b | tonumber), default_ttl: $t,
     in_words: ((if $a == "ask" then "asks before every trade" else "trades without asking" end)
                + " · market orders within \($b)% of the price · limit orders rest \($t | words)")}'
}

# bc_int EXPR: evaluate an integer expression with bc.
bc_int() { echo "scale=0; $1" | bc | tr -d '\\\n'; }

# since_us WHEN: a time as microseconds since 1970. WHEN is 30m, 24h, 7d, 2026-11-01 or
# 2026-11-01T12:00:00Z (UTC). Prints nothing and returns 1 when WHEN is not understood.
since_us() {
  local w="$1" n="" unit=0 s
  case "$w" in
    *m) n=${w%m}; unit=60 ;;
    *h) n=${w%h}; unit=3600 ;;
    *d) n=${w%d}; unit=86400 ;;
  esac
  if [ "$unit" != 0 ]; then
    case "$n" in ''|*[!0-9]*) return 1 ;; esac
    s=$(( $(date +%s) - n * unit ))
  else
    case "$w" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
        s=$(date -j -u -f '%Y-%m-%d %H:%M:%S' "$w 00:00:00" +%s 2>/dev/null) || return 1 ;;
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z)
        s=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$w" +%s 2>/dev/null) || return 1 ;;
      *) return 1 ;;
    esac
  fi
  echo $(( s * 1000000 ))
}

# --- profile ------------------------------------------------------------------------------------------

profile_exists() { [ -f "$PROFILE" ]; }

profile_get() { jq -r "$1" "$PROFILE"; }

# --- send outcomes (status decision T4) -------------------------------------------------------------

# send_failure_kind CODE MESSAGE: "lasting" when pod refused for a reason that will not pass by
# itself (region, blacklist, frozen account), otherwise "passing" (timeouts, nonce clashes, busy).
send_failure_kind() {
  local code="$1" msg
  msg=$(echo "$2" | tr 'A-Z' 'a-z')
  [ "$code" = "-32025" ] && { echo lasting; return; }
  case "$msg" in
    *region*|*blacklist*|*locked*|*equivocat*|*recover*) echo lasting ;;
    *) echo passing ;;
  esac
}

# record_send OK LASTING TX ERROR: store the latest send's outcome in the profile as `last_send`.
# Never fails the caller: a send that went through must not be reported as failed because of this.
record_send() {
  profile_exists || return 0
  local updated
  updated=$(jq --argjson ok "$1" --argjson lasting "$2" --arg tx "$3" --arg err "$4" --arg at "$(now_iso)" '
    .last_send = ({ok: $ok, at: $at}
      + (if $tx == "" then {} else {tx: $tx} end)
      + (if $ok then {} else {lasting: $lasting, error: $err} end))' "$PROFILE" 2>/dev/null) || return 0
  echo "$updated" | profile_write >/dev/null 2>&1 || true
}

short_addr() { local a="$1"; echo "${a:0:6}…${a: -4}"; }

profile_write() {   # reads the full profile JSON on stdin
  mkdir -p "$POD_HOME"
  chmod 700 "$POD_HOME"
  local tmp="$PROFILE.tmp.$$"
  (umask 077; cat > "$tmp")
  jq -e . "$tmp" >/dev/null || { rm -f "$tmp"; fail profile "Refused to save a profile that is not valid JSON."; }
  mv "$tmp" "$PROFILE"
  chmod 600 "$PROFILE"
}
