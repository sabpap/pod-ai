#!/usr/bin/env bash
# Offline checks of the pod command's contract: every manual prints and is complete, every option a
# script accepts is in its command's manual, the scripts run only through pod, and no message names a
# Claude Code skill or a script path. No network, no wallet.
# Usage: cli/tests/contract.sh

set -uo pipefail
CLI="$(cd "$(dirname "$0")/.." && pwd)"
POD="$CLI/pod"
L="$CLI/libexec"
export POD_PLUGIN_HOME="$(mktemp -d)"
trap 'rm -rf "$POD_PLUGIN_HOME"' EXIT

pass=0; failed=0
ok()   { pass=$((pass+1)); echo "ok   $1"; }
bad()  { failed=$((failed+1)); echo "FAIL $1"; }

COMMANDS="setup status settings account markets live trade wallet"
script_of() {
  case "$1" in setup) echo setup.sh ;; status) echo status.sh ;; settings) echo profile.sh ;; account) echo account.sh ;;
               markets) echo markets.sh ;; live) echo live.sh ;; trade) echo trade.sh ;; wallet) echo wallet.sh ;; esac
}

# --- the top manual -------------------------------------------------------------------------------------
top=$("$POD" --help); code=$?
[ $code = 0 ] && [ -n "$top" ] && ok "pod --help exits 0" || bad "pod --help: exit $code"
for c in $COMMANDS help --version; do
  echo "$top" | grep -Eq "^  $c " && ok "pod --help lists $c" || bad "pod --help does not list $c"
done
for w in "Order of work" "Exit codes" "plan, approve, send, follow" "pod trade send PLAN_ID" "pod trade follow PLAN_ID"; do
  echo "$top" | grep -q "$w" && ok "pod --help has: $w" || bad "pod --help lacks: $w"
done
[ "$("$POD" help)" = "$top" ] && [ "$("$POD")" = "$top" ] && [ "$("$POD" -h)" = "$top" ] && ok "pod, pod help and pod -h print the same manual" || bad "top manuals differ"
v=$("$POD" --version); echo "$v" | grep -Eq '^pod [0-9]+\.[0-9]+\.[0-9]+$' && ok "pod --version: $v" || bad "pod --version: $v"

# --- each command's manual, at every level ----------------------------------------------------------------
subs() {   # the words that follow each command
  case "$1" in
    setup)    echo "wallets show test disconnect tools network" ;;
    status)   echo "" ;;
    settings) echo "show set" ;;
    account)  sed -n 's/^VIEWS="\(.*\)"$/\1/p' "$L/account.sh" ;;
    markets)  sed -n 's/^VIEWS="\(.*\)"$/\1/p' "$L/markets.sh" ;;
    live)     echo "$(sed -n 's/^CHANNELS="\(.*\)"$/\1/p' "$L/live.sh") list stop" ;;
    trade)    echo "buy sell close edit cancel cancel-all stop-loss take-profit edit-trigger cancel-trigger send follow" ;;
    wallet)   echo "address type" ;;
  esac
}
for c in $COMMANDS; do
  m=$("$POD" "$c" --help); code=$?
  { [ $code = 0 ] && echo "$m" | head -1 | grep -q "^pod $c: "; } && ok "pod $c --help exits 0" || bad "pod $c --help: exit $code"
  [ "$("$POD" help "$c")" = "$m" ] && [ "$("$POD" "$c" -h)" = "$m" ] && ok "pod help $c and pod $c -h match" || bad "pod help $c differs"
  for s in $(subs "$c"); do
    out=$("$POD" "$c" "$s" --help); code=$?
    [ $code = 0 ] && [ "$out" = "$m" ] && sok=1 || sok=0
    echo "$m" | grep -Eq "(^|[^a-z-])$s([^a-z-]|$)" && wok=1 || wok=0
    [ $sok = 1 ] && [ $wok = 1 ] && ok "pod $c $s --help: exits 0, named in the manual" || bad "pod $c $s --help (exit $code, named: $wok)"
  done
done

# --- every option a script accepts is in its command's manual -------------------------------------------------
# Options of internal actions that pod does not expose are listed here with the reason.
internal() {
  case "$1:$2" in
    profile.sh:--keystore|profile.sh:--env|profile.sh:--address) return 0 ;;   # profile.sh save, used by setup.sh
    wallet.sh:--keystore|wallet.sh:--env|wallet.sh:--nonce) return 0 ;;         # used by setup, status and trade only
  esac
  return 1
}
manual_for_script() {
  case "$1" in
    setup.sh|test-transaction.sh|check-tools.sh|check-network.sh|list-wallets.sh) echo setup ;;
    status.sh) echo status ;; profile.sh) echo settings ;; account.sh) echo account ;; markets.sh) echo markets ;;
    live.sh) echo live ;; trade.sh) echo trade ;; wallet.sh) echo wallet ;;
  esac
}
for f in "$L"/*.sh; do
  s=$(basename "$f"); [ "$s" = lib.sh ] && continue
  c=$(manual_for_script "$s"); m=$("$POD" "$c" --help)
  opts=$(grep -Eo -- '--[a-z][a-z-]*(\|--[a-z][a-z-]*)*\)' "$f" | tr '|)' '\n\n' | grep -E '^--' | sort -u)
  n=0
  for o in $opts; do
    internal "$s" "$o" && continue
    n=$((n+1))
    echo "$m" | grep -q -- "$o" && ok "$s $o is in pod $c --help" || bad "$s $o is missing from pod $c --help"
  done
done

# The values a command checks are in its manual too
check_words() {   # check_words COMMAND WORDS...
  local c="$1"; shift; local m; m=$("$POD" "$c" --help)
  for w in "$@"; do echo "$m" | grep -q -- "$w" && ok "pod $c --help names $w" || bad "pod $c --help lacks $w"; done
}
check_words account $(sed -n 's/^STATUSES="\(.*\)"$/\1/p' "$L/account.sh")
check_words markets $(sed -n 's/^SORTS="\(.*\)"$/\1/p' "$L/markets.sh") $(sed -n 's/^RESOLUTIONS="\(.*\)"$/\1/p' "$L/markets.sh")
check_words settings approval market_band_pct default_ttl ask auto in_words
check_words live "<=" ">=" "!=" "condition met" "watching" "notice" "stopped"
check_words trade plan_id summary preview notes needs_approval value_at_current_price_usd order_value_usd "units of the asset" "--usd" final outcome
check_words status "not set up" "problem" "connected, read-only" "connected, untested" "ready to trade" summary problems warnings capabilities
check_words setup needs_approval "ready to trade" test_transaction "pod setup test --yes"

# --- the contract in the code ----------------------------------------------------------------------------------
hits=$(grep -rn 'CLAUDE_PLUGIN_ROOT' "$CLI" --include='*' | grep -v '/tests/contract.sh' || true)
[ -z "$hits" ] && ok "no CLAUDE_PLUGIN_ROOT in the CLI" || bad "CLAUDE_PLUGIN_ROOT in the CLI: $hits"
hits=$(grep -rn '/pod:' "$CLI/libexec" "$CLI/pod" || true)
[ -z "$hits" ] && ok "no /pod: skill names in the CLI" || bad "skill names in the CLI: $hits"
# A message (fail, fix, next, note, error) never names a script: it names a pod command.
hits=$(grep -n -E '(fail|fail_usage|refuse)\b.*"[^"]*[a-z-]+\.(sh|mjs)\b|next: .*\.sh|note: .*\.sh' "$L"/*.sh "$L"/*.mjs | grep -v -E ':[0-9]+:\s*#' || true)
[ -z "$hits" ] && ok "no message names a script" || bad "a message names a script: $hits"
for f in "$L"/*.sh; do
  s=$(basename "$f"); [ "$s" = lib.sh ] && continue
  out=$(env -u POD_CLI "$f" 2>/dev/null); code=$?
  { [ $code = 2 ] && echo "$out" | jq -e '.ok == false and .step == "usage"' >/dev/null 2>&1; } && ok "$s refuses to run without pod" || bad "$s ran without pod (exit $code)"
done
[ -x "$POD" ] && ok "pod is executable" || bad "pod is not executable"

# Exit code 2 and JSON for usage errors at the top
out=$("$POD" nosuch); code=$?
{ [ $code = 2 ] && echo "$out" | jq -e '.ok == false and .step == "usage" and (.fix | test("pod help"))' >/dev/null; } && ok "unknown command: JSON, exit 2" || bad "unknown command: exit $code, $out"
out=$("$POD" settings set approval); code=$?
[ $code = 2 ] && ok "settings set with one word: exit 2" || bad "settings set with one word: exit $code"

echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
