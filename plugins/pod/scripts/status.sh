#!/usr/bin/env bash
# Can the AI act on pod right now, and if not, why not? Also lists what it can and cannot do.
#
# Usage:
#   status.sh            full check: also signs a test message with the wallet (reads the Keychain)
#   status.sh --quick    the same without signing
#
# Levels, first match wins: not set up · problem · connected, read-only · connected, untested ·
# ready to trade. Spec: specs/03-status.md.

source "$(dirname "$0")/lib.sh"
HERE="$(dirname "$0")"

mode=full
case "${1:-}" in
  --quick) mode=quick ;;
  "") ;;
  *) fail status "Unknown option $1." "Use --quick, or nothing for the full check." ;;
esac

problems="[]"; warnings="[]"
add_problem() { problems=$(echo "$problems" | jq --arg c "$1" --arg e "$2" --arg f "${3:-}" '. + [{check: $c, error: $e} + (if $f == "" then {} else {fix: $f} end)]'); }
add_warning() { warnings=$(echo "$warnings" | jq --arg w "$1" '. + [$w]'); }

# --- 1 profile -------------------------------------------------------------------------------------

has_profile=false; ADDR=""
if profile_exists; then
  has_profile=true
  ADDR=$(profile_get '.wallet.address')
fi

# --- 2, 5, 6 network and account, all calls in parallel ---------------------------------------------

D=$(mktemp -d "${TMPDIR:-/tmp}/pod-status.XXXXXX")
trap 'rm -rf "$D"' EXIT

# Each call is tried twice: staging sometimes drops a single request, and one dropped read must not
# turn the level into "problem".
get()  { curl -sS --fail --max-time 5 --retry 1 --retry-delay 1 --retry-all-errors "$POD_REST$2" > "$D/$1" 2>/dev/null || rm -f "$D/$1"; }
call() { curl -sS --fail --max-time 5 --retry 1 --retry-delay 1 --retry-all-errors -X POST "$POD_RPC" -H 'content-type: application/json' \
           -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$2\",\"params\":$3}" > "$D/$1" 2>/dev/null || rm -f "$D/$1"; }

get status /clob/status &
call chain eth_chainId '[]' &
call pod pod_status '[]' &
if $has_profile; then
  get balances "/clob/balances/$ADDR" &
  get positions "/clob/positions/$ADDR" &
  get orders "/clob/orders/$ADDR?status=active&limit=500" &
  call diag pod_getAccountDiagnostics "[\"$ADDR\"]" &
fi
wait

net_up=false; writes_open=false
if [ -s "$D/status" ] && [ -s "$D/chain" ] && [ -s "$D/pod" ]; then
  chain=$(printf '%d' "$(jq -r '.result' "$D/chain")" 2>/dev/null || echo 0)
  if [ "$chain" = "$STAGING_CHAIN_ID" ]; then
    net_up=true
    [ "$(jq '.result.read_only or .result.paused' "$D/pod")" = "false" ] && writes_open=true
  else
    add_problem network "Pod answered with chain id $chain, not pod staging ($STAGING_CHAIN_ID)." "Nothing can be done until pod staging answers on its usual address."
  fi
else
  add_problem network "Pod staging did not answer within 5 seconds." "Try again later."
fi

# --- 3, 4 wallet --------------------------------------------------------------------------------------

wallet="null"; present=false; signs="null"
if $has_profile; then
  wtype=$(profile_get '.wallet.type')
  if [ "$wtype" = "keystore" ]; then
    wref=$(profile_get '.wallet.keystore')
    if [ ! -f "$KEYSTORE_DIR/$wref" ]; then
      add_problem wallet "The keystore $wref is no longer in $KEYSTORE_DIR." "Restore it, or connect another wallet with /pod:setup."
    elif ! security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$wref" >/dev/null 2>&1; then
      add_problem wallet "The keystore $wref has no password in the Keychain." "Run: security add-generic-password -s $KEYCHAIN_SERVICE -a $wref -w"
    else
      present=true
    fi
  else
    wref=$(profile_get '.wallet.env_var')
    if [ -z "${!wref:-}" ]; then
      add_problem wallet "The variable $wref is not set in this session." "Export it in the shell that starts Claude Code."
    else
      present=true
    fi
  fi

  if [ "$mode" = full ] && $present; then
    msg="pod plugin status check $(now_iso)"
    sig=$("$HERE/wallet.sh" sign-message "$msg" 2>/dev/null | jq -r '.signature // empty')
    if [ -n "$sig" ] && cast wallet verify --address "$ADDR" "$msg" "$sig" >/dev/null 2>&1; then
      signs=true
    else
      signs=false
      add_problem wallet "The wallet could not sign as $ADDR." "Check the keystore password or the private key; or connect again with /pod:setup."
    fi
  fi

  wallet=$(jq -n --arg t "$wtype" --arg r "$wref" --arg a "$ADDR" --argjson p "$present" --argjson s "$signs" '
    {type: $t} + (if $t == "keystore" then {keystore: $r} else {env_var: $r} end)
    + {address: $a, present: $p, signs: $s}')
fi

# --- account ---------------------------------------------------------------------------------------------

account="null"; cash="0"
if $has_profile && $net_up; then
  if [ -s "$D/balances" ] && [ -s "$D/positions" ] && [ -s "$D/orders" ]; then
    cash=$(to_dec "$(jq -r '.cash' "$D/balances")")
    frozen=false
    if [ -s "$D/diag" ] && [ "$(jq '.result | (.is_locked or .needs_recovery or .equivocating)' "$D/diag")" = "true" ]; then
      frozen=true
      add_problem account "The account is frozen on pod (locked or waiting for recovery)." "Recovery is not part of this plugin; see pod's guide 'Recover a locked account'."
    fi
    account=$(jq -n --arg c "$(human "$cash")" \
      --arg w "$(human "$(to_dec "$(jq -r '.withdrawable_cash' "$D/balances")")")" \
      --arg v "$(human "$(to_dec "$(jq -r '.account_value' "$D/positions")")")" \
      --argjson p "$(jq '.positions | length' "$D/positions")" \
      --argjson o "$(jq '.total_count // (.orders | length)' "$D/orders")" --argjson f "$frozen" \
      '{cash_usd: $c, withdrawable_usd: $w, account_value_usd: $v, open_positions: $p, open_orders: $o, frozen: $f}')
  else
    add_problem account "Pod answered, but the account could not be read." "Try again in a moment."
  fi
fi

# --- 7 proof of sending ----------------------------------------------------------------------------------

proof="null"; proven=false
if $has_profile; then
  proof=$(jq '{test_transaction: .test_transaction, last_send: .last_send}' "$PROFILE")
  verdict=$(echo "$proof" | jq -r '
    .test_transaction as $t | .last_send as $s
    | if ($s != null and $s.ok == false and $s.lasting == true) then "lasting-failure"
      elif ($t != null and $t.result == "failed" and ($s == null or $s.ok != true or $s.at < $t.at)) then "test-failed"
      elif (($t != null and $t.result == "passed") or ($s != null and $s.ok == true)) then "proven"
      else "unproven" end')
  case "$verdict" in
    lasting-failure) add_problem sending "$(echo "$proof" | jq -r '.last_send.error')" "Pod refuses this account's transactions; a test with /pod:setup shows whether it still does." ;;
    test-failed)     add_problem sending "The test transaction failed: $(echo "$proof" | jq -r '.test_transaction.error')" "Run the test again with /pod:setup." ;;
    proven)          proven=true ;;
  esac
fi

# --- level ------------------------------------------------------------------------------------------------

funded=$([ "$(bc_int "$cash > 0")" = "1" ] && echo true || echo false)
reason=""
if ! $has_profile; then
  level="not set up"
elif [ "$(echo "$problems" | jq length)" != "0" ]; then
  level="problem"
elif ! $writes_open; then
  level="connected, read-only"; reason="pod is paused or read-only right now"
elif ! $funded; then
  level="connected, read-only"; reason="the account has no cash on pod"
elif ! $proven; then
  level="connected, untested"
  add_warning "No test transaction has passed yet, so trading is unproven: the first trade will be the proof. To prove it first, run the test with /pod:setup."
else
  level="ready to trade"
fi
[ -n "$reason" ] && add_warning "Read-only: $reason."

can_trade=$([ "$level" = "ready to trade" ] || [ "$level" = "connected, untested" ] && echo true || echo false)
trade_why=""
case "$level" in
  "not set up") trade_why="no wallet is connected; run /pod:setup" ;;
  problem) trade_why="$(echo "$problems" | jq -r '.[0].error')" ;;
  "connected, read-only") trade_why="$reason" ;;
  "connected, untested") trade_why="allowed, but not yet proven" ;;
esac

summary_line=""
case "$level" in
  "not set up") summary_line="pod: not set up · run /pod:setup to connect a wallet" ;;
  problem) summary_line="pod: problem · $(echo "$problems" | jq -r '.[0].error')" ;;
  "connected, read-only") summary_line="pod: read-only · $reason · $(short_addr "$ADDR")" ;;
  *) summary_line="pod: $level · $(short_addr "$ADDR") · \$$(echo "$account" | jq -r '.cash_usd') cash · $(echo "$account" | jq -r '.open_positions') positions · $(echo "$account" | jq -r '.open_orders') orders" ;;
esac

jq -n --arg level "$level" --arg mode "$mode" --arg line "$summary_line" \
  --argjson net_up "$net_up" --argjson writes "$writes_open" --argjson wallet "$wallet" \
  --argjson account "$account" --argjson proof "$proof" --argjson can_trade "$can_trade" --arg trade_why "$trade_why" \
  --argjson problems "$problems" --argjson warnings "$warnings" --arg name "$STAGING_NAME" --argjson chain "$STAGING_CHAIN_ID" '
  {ok: true, level: $level, summary: $line, check: $mode,
   network: {name: $name, chain_id: $chain, answers: $net_up, writes_open: $writes},
   wallet: $wallet, account: $account, proof: $proof,
   capabilities: [
     {name: "read markets and prices", can: $net_up},
     {name: "read any account", can: $net_up},
     {name: "follow live updates", can: $net_up, note: "needs a listener kept open by the harness"},
     ({name: "trade with this wallet", can: $can_trade} + (if $trade_why == "" then {} else {why: $trade_why} end)),
     {name: "deposit, withdraw, transfer", can: false, why: "not part of this plugin"},
     {name: "bot keys (delegation)", can: false, why: "not part of this plugin"},
     {name: "recover a frozen account", can: false, why: "not part of this plugin"}
   ],
   problems: $problems, warnings: $warnings}'
