#!/usr/bin/env bash
# pod-guard: a Claude Code PreToolUse hook that makes Claude Code ask the person before the agent
# sends from the pod wallet, or switches approval off. Design: specs/08-cli-and-hook.md.
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
# inside bash -c "...", after env assignments, by any path to pod) and errs on the side of asking. A
# trade, setup or wallet word counts only after pod or something that may stand for pod (a variable,
# a command substitution), or as the script itself, so a commit message saying "trade send" passes.
# For a send it shows the plan (summary, value, fee, margin, notes): its prompt is the only question.
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
flatten() { tr -d "'\"\\\\" | tr ';|&()<>{}\`$=,:' '              ' | tr 'A-Z' 'a-z'; }
flat=$(printf '%s' "$text" | flatten)
# For the word scan, a variable ($x, ${x}) or a command substitution ($(...), `...`) becomes the word
# __var__ first: it may stand for pod, so it counts like pod.
words=$(printf '%s' "$text" | sed -E 's/\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/ __var__ /g; s/\$\(/ __var__ (/g; s/`/ __var__ /g' | flatten)

# A trade, setup or wallet word counts only after pod (by any path), a word that may stand for pod
# (__var__), or as the script itself (trade.sh, wallet.sh, test-transaction.sh, libexec/setup.sh). So
# git commit -m "trade send fix" passes, while x=pod; $x trade send, alias p=pod; p trade send and
# f() { pod "$@"; }; f trade send still ask: pod, or a stand-in, comes first in each.
SEND=false; ALWAYS=""; KIND=""
saw_pod=false; saw_trade=false; saw_setup=false; saw_wallet=false; saw_cast=false; plans=""
for w in $words; do
  b="${w##*/}"
  case "$b" in
    pod|__var__) saw_pod=true ;;
    trade) $saw_pod && saw_trade=true ;;
    trade.sh) saw_trade=true ;;
    setup) $saw_pod && saw_setup=true ;;
    setup.sh) case "$w" in *libexec/*) saw_setup=true ;; *) $saw_pod && saw_setup=true ;; esac ;;
    test-transaction.sh) saw_setup=true ;;
    wallet) $saw_pod && saw_wallet=true ;;
    wallet.sh) saw_wallet=true ;;
    cast) saw_cast=true ;;
    send|--send)
      { $saw_trade || $saw_wallet; } && { SEND=true; KIND="${KIND:-trade}"; }
      $saw_cast && ALWAYS="raw" ;;
    mktx|publish) $saw_cast && ALWAYS="raw" ;;
    --yes|-y) $saw_setup && { SEND=true; KIND="${KIND:-setup}"; } ;;
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
    # The plan, in words, so this prompt can be the only question the person sees.
    summary=""
    if $HAVE_JQ; then
      for id in $plans; do
        f="$HOME_DIR/plans/$id.json"
        [ -r "$f" ] || continue
        s=$(jq -r '. as $p | .preview as $v
          | def num: test("^-?[0-9.]+$");
          [ ($p.summary + "."),
            (if $v.value_at_current_price_usd then "Value about $\($v.value_at_current_price_usd) at the current price, at most $\($v.order_value_usd) at the worst price."
             elif $v.order_value_usd then "Value $\($v.order_value_usd)." else empty end),
            (if $v.fee_usd then "Fee $\($v.fee_usd)." else empty end),
            (if ($v.margin_needed_usd // "" | num) then "Margin $\($v.margin_needed_usd)" + (if $v.free_margin_after_usd then ", free margin after $\($v.free_margin_after_usd)." else "." end) else empty end),
            (if $v.cash_available_usd then "Cash available $\($v.cash_available_usd)." else empty end),
            (if $v.tokens_available then "Tokens available \($v.tokens_available)." else empty end),
            ($p.notes // [] | .[] | "Note: \(.).")
          ] | join(" ")' "$f" 2>/dev/null) || s=""
        [ -n "$s" ] && summary="${summary:+$summary | }$s (plan $id)"
      done
    fi
    cmd=$(printf '%s' "$text" | tr '\n\r\t' '   '); cmd="${cmd:0:300}"
    if [ -n "$summary" ]; then what="Send this trade from your pod wallet? $summary"
    elif [ "$KIND" = setup ]; then what="Send pod's setup test transaction from your wallet? A maker-only buy of the smallest size at half the oracle price, so it cannot fill, cancelled as soon as it rests: two real transactions on pod staging. Command: $cmd"
    else what="This sends a transaction from your pod wallet. Command: $cmd"; fi
    what="$what Approve to send it; deny and nothing is sent. (pod's approval setting is ask.)" ;;
esac

case "$mode" in
  bypassPermissions|dontAsk)
    decide deny "pod: $what Blocked: this session's permission mode ($mode) cannot ask the person, and pod needs their yes. Nothing was run. Ask the person to run the command in their own terminal, or to switch to a permission mode that asks." ;;
  *)
    decide ask "pod: $what" ;;
esac
