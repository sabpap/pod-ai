#!/usr/bin/env bash
# pod-guard: a Claude Code PreToolUse hook that makes Claude Code ask the person before the agent
# sends from the pod wallet, or switches approval off. Design: specs/02-cli-and-hook.md.
#
# Reads the PreToolUse JSON on stdin. Prints nothing (no opinion: the normal permission flow goes on),
# or one hookSpecificOutput object with permissionDecision "ask" or "deny".
#
# What it guards, by the command's text:
#   send      pod trade send, any pod trade action with --send, pod setup ... --yes (the test
#             transaction), and the scripts behind them (trade.sh, wallet.sh send, test-transaction.sh,
#             POD_CLI=1). Asked while the approval setting is "ask"; passes when it is "auto".
#   always    approval set to auto; pod's own files (profile, settings, plans) or POD_PLUGIN_HOME;
#             the wallet itself (the keystore folder, its Keychain password, cast send / mktx /
#             publish, eth_sendRawTransaction). Asked whatever the setting.
# It reads the text loosely (quotes and backslashes dropped, any position in a pipeline, after && or ;,
# inside bash -c "...", after env assignments, by any path to pod) and errs on the side of asking.
# Write, Edit, MultiEdit and NotebookEdit are checked too: a file under pod's folder always asks, and a
# script (not .md or .txt) whose new text would send asks like the command itself.
#
# Where Claude Code cannot show the question (permission mode bypassPermissions or dontAsk), it
# answers "deny" instead of "ask", so nothing is sent unasked.

set -uo pipefail
set -f   # no globbing while splitting words

input=$(cat)
HOME_DIR="${POD_PLUGIN_HOME:-$HOME/.config/pod-plugin}"

# Fast exit for the many commands that cannot concern pod (quotes dropped first: tr""ade is trade).
case "$input" in
  *"$HOME_DIR"*) ;;
  *) printf '%s' "$input" | tr -d "'\"\\\\" \
       | grep -Eiq 'trade|setup|wallet|cast|approval|pod-plugin|pod_plugin|pod_cli|foundry|eth_send|test-transaction' \
       || exit 0 ;;
esac
HAVE_JQ=false; command -v jq >/dev/null 2>&1 && HAVE_JQ=true

json_str() {   # json_str TEXT: TEXT as a JSON string, without jq
  local s="$1"
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=$(printf '%s' "$s" | tr '\n\r\t' '   ')
  printf '"%s"' "$s"
}

decide() {   # decide ask|deny REASON
  printf '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "%s", "permissionDecisionReason": %s}}\n' \
    "$1" "$(json_str "$2")"
  exit 0
}

# --- what the tool call would do -----------------------------------------------------------------------

mode=$(printf '%s' "$input" | grep -Eo '"permission_mode"[[:space:]]*:[[:space:]]*"[A-Za-z]+"' | head -1 | sed -E 's/.*"([A-Za-z]+)"$/\1/')
tool=""; path=""; text=""
if $HAVE_JQ && printf '%s' "$input" | jq -e . >/dev/null 2>&1; then
  tool=$(printf '%s' "$input" | jq -r '.tool_name // ""')
  path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""')
  text=$(printf '%s' "$input" | jq -r '.tool_input | [.command, .content, .new_string, .new_source, (.edits // [] | .[].new_string)]
                                         | map(select(type == "string")) | join("\n")')
else
  text="$input"   # no jq, or not JSON: scan everything, err on the side of asking
fi

case "$tool" in
  Write|Edit|MultiEdit|NotebookEdit)
    case "$path" in
      "$HOME_DIR"/*|*/pod-plugin/*) ;;              # pod's own files: checked below as "always"
      *.md|*.markdown|*.txt|*.rst|*.html) exit 0 ;;  # prose may name commands without running them
    esac ;;
esac

# Loose reading: drop quotes and backslashes, turn shell punctuation into spaces, lower case.
flat=$(printf '%s' "$text" | tr -d "'\"\\\\" | tr ';|&()<>{}\`$=,:' '              ' | tr 'A-Z' 'a-z')

SEND=false; ALWAYS=""
saw_trade=false; saw_setup=false; saw_wallet=false; saw_cast=false; plans=""
for w in $flat; do
  b="${w##*/}"
  case "$b" in
    trade|trade.sh) saw_trade=true ;;
    setup|setup.sh|test-transaction.sh) saw_setup=true ;;
    wallet|wallet.sh) saw_wallet=true ;;
    cast) saw_cast=true ;;
    send|--send)
      { $saw_trade || $saw_wallet; } && SEND=true
      $saw_cast && ALWAYS="raw" ;;
    mktx|publish) $saw_cast && ALWAYS="raw" ;;
    --yes|-y) $saw_setup && SEND=true ;;
    p[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) plans="$plans $b" ;;
  esac
done
case "$flat" in *pod_cli*) SEND=true ;; esac
case "$flat" in *eth_sendrawtransaction*|*foundry-keystore*|*.foundry/keystores*) ALWAYS="raw" ;; esac
case "$flat" in *pod-plugin*|*pod_plugin_home*) ALWAYS="home" ;; esac
case "$path" in "$HOME_DIR"/*|*/pod-plugin/*) ALWAYS="home" ;; esac
printf '%s' "$flat" | grep -Eq 'approval[[:space:]]+auto' && ALWAYS="approval"

{ $SEND || [ -n "$ALWAYS" ]; } || exit 0

# --- the approval setting: "auto" lets sends through; anything unreadable counts as "ask" ----------------

approval=ask
if [ -r "$HOME_DIR/profile.json" ] && grep -Eq '"approval"[[:space:]]*:[[:space:]]*"auto"' "$HOME_DIR/profile.json"; then
  approval=auto
fi
[ -z "$ALWAYS" ] && [ "$approval" = auto ] && exit 0

# --- what the person is asked ----------------------------------------------------------------------------

what=""
case "$ALWAYS" in
  approval) what="This switches pod's approval setting to auto: from then on the agent sends trades without asking you. Approve only if you asked for that." ;;
  home)     what="This reads or changes pod's own files (profile, settings or plans) directly, outside the pod command. Approve only if you expect it." ;;
  raw)      what="This uses the wallet directly (its keystore, its Keychain password, or a raw transaction), outside pod trade. Approve only if you expect it." ;;
  *)
    summary=""
    if $HAVE_JQ; then
      for id in $plans; do
        f="$HOME_DIR/plans/$id.json"
        [ -r "$f" ] || continue
        s=$(jq -r '.summary + (if .preview.order_value_usd then " · value $" + .preview.order_value_usd else "" end)
                   + (if .preview.value_at_current_price_usd then " (about $" + .preview.value_at_current_price_usd + " at the current price)" else "" end)
                   + (if .preview.fee_usd then " · fee $" + .preview.fee_usd else "" end)
                   + (if (.preview.margin_needed_usd // "" | test("^[0-9.]+$")) then " · margin $" + .preview.margin_needed_usd else "" end)
                   + (if (.notes | length) > 0 then " · notes: " + (.notes | join("; ")) else "" end)' "$f" 2>/dev/null) || s=""
        [ -n "$s" ] && summary="${summary:+$summary | }$id: $s"
      done
    fi
    if [ -n "$summary" ]; then what="This sends from your pod wallet: $summary. Approve only if you want this trade."
    else what="This sends a transaction from your pod wallet. Approve only if you asked for it."; fi
    what="$what (pod's approval setting is ask.)" ;;
esac

case "$mode" in
  bypassPermissions|dontAsk)
    decide deny "pod: $what Blocked: this session's permission mode ($mode) cannot ask the person, and pod needs their yes. Nothing was run. Ask the person to run the command in their own terminal, or to switch to a permission mode that asks." ;;
  *)
    decide ask "pod: $what" ;;
esac
