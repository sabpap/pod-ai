#!/usr/bin/env bash
# Unit tests of the pod-guard hook: feed it PreToolUse JSON, check its decision. No network, no wallet,
# no Claude Code. Uses a throwaway POD_PLUGIN_HOME with a fake profile and a fake plan.
# Usage: plugins/pod/tests/guard.sh

set -uo pipefail
HOOK="$(cd "$(dirname "$0")/../hooks" && pwd)/pod-guard.sh"
export POD_PLUGIN_HOME="$(mktemp -d)"
trap 'rm -rf "$POD_PLUGIN_HOME"' EXIT
H="$POD_PLUGIN_HOME"

PLAN=p1234abcd
mkdir -p "$H/plans"
cat > "$H/plans/$PLAN.json" <<'EOF'
{"plan_id": "p1234abcd", "summary": "buy 0.5 NVDA perp at $150, rests 1 day",
 "preview": {"order_value_usd": "75", "fee_usd": "0.03", "margin_needed_usd": "3.75"},
 "notes": ["price 150.004 → 150 (rounded down)"]}
EOF
approval() {   # approval ask|auto|none|broken: the profile's setting
  case "$1" in
    none) rm -f "$H/profile.json" ;;
    broken) echo '{not json' > "$H/profile.json" ;;
    *) printf '{\n  "wallet": {"type": "keystore", "keystore": "x"},\n  "settings": {\n    "approval": "%s"\n  }\n}\n' "$1" > "$H/profile.json" ;;
  esac
}

# decide MODE TOOL TEXT [PATH]: the hook's decision: ask, deny or none. Sets REASON.
decide() {
  local mode="$1" tool="$2" text="$3" path="${4:-}" in out
  in=$(jq -n --arg m "$mode" --arg t "$tool" --arg x "$text" --arg p "$path" '
    {session_id: "s", cwd: "/tmp", permission_mode: $m, hook_event_name: "PreToolUse", tool_name: $t,
     tool_use_id: "t1",
     tool_input: (if $t == "Write" then {file_path: $p, content: $x}
                  elif $t == "Edit" then {file_path: $p, old_string: "a", new_string: $x}
                  elif $t == "MultiEdit" then {file_path: $p, edits: [{old_string: "a", new_string: $x}]}
                  else {command: $x, description: "d"} end)}')
  out=$(printf '%s' "$in" | "$HOOK")
  REASON=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null)
  if [ -z "$out" ]; then echo none
  else printf '%s' "$out" | jq -r 'if .hookSpecificOutput.hookEventName == "PreToolUse" then .hookSpecificOutput.permissionDecision else "bad-output" end' 2>/dev/null || echo bad-output
  fi
}

pass=0; failed=0
is() {   # is NAME WANT MODE TOOL TEXT [PATH]
  local name="$1" want="$2" got; shift 2
  got=$(decide "$@")
  if [ "$got" = "$want" ]; then pass=$((pass+1)); echo "ok   $name"
  else failed=$((failed+1)); echo "FAIL $name: got $got, want $want"; fi
}
reason_has() {   # reason_has NAME PATTERN MODE TOOL TEXT
  local name="$1" pat="$2"; shift 2
  decide "$@" >/dev/null   # not in $(...), so REASON stays set here
  if printf '%s' "$REASON" | grep -Eiq "$pat"; then pass=$((pass+1)); echo "ok   $name"
  else failed=$((failed+1)); echo "FAIL $name: reason was: $REASON"; fi
}

approval ask
D=default

# Reading and planning pass through untouched
is "status passes"                 none $D Bash "pod status --quick"
is "markets passes"                none $D Bash "pod markets list nvda"
is "account passes"                none $D Bash "pod account positions 0x035A9E2f3ED8bAAD656E66BF3f0071da40DcDa70"
is "live passes"                   none $D Bash "pod live market NVDA --until 'mark < 140'"
is "planning a buy passes"         none $D Bash "pod trade buy NVDA --usd 10 --market"
is "planning a cancel-all passes"  none $D Bash "pod trade cancel-all"
is "following passes"              none $D Bash "pod trade follow $PLAN"
is "trade manual passes"           none $D Bash "pod trade --help"
is "settings show passes"          none $D Bash "pod settings"
is "band change passes"            none $D Bash "pod settings set market_band_pct 1.5"
is "approval back to ask passes"   none $D Bash "pod settings set approval ask"
is "setup test plan passes"        none $D Bash "pod setup test"
is "setup test dry run passes"     none $D Bash "pod setup test --dry-run"
is "setup without --yes passes"    none $D Bash "pod setup --keystore dev"
is "unrelated command passes"      none $D Bash "ls -la && git status"

# Sends ask, however they are written
is "send asks"                     ask $D Bash "pod trade send $PLAN"
is "one-step --send asks"          ask $D Bash "pod trade buy NVDA 0.5 --price 150 --send"
is "in a pipeline"                 ask $D Bash "pod trade send $PLAN | jq .summary"
is "after &&"                      ask $D Bash "pod status --quick && pod trade send $PLAN"
is "after ;"                       ask $D Bash "echo go; pod trade send $PLAN"
is "after ||"                      ask $D Bash "false || pod trade send $PLAN"
is "in a subshell"                 ask $D Bash "(cd /tmp && pod trade send $PLAN)"
is "in a command substitution"     ask $D Bash 'echo "$(pod trade send '"$PLAN"')"'
is "env-var prefixes"              ask $D Bash "FOO=1 BAR=x pod trade send $PLAN"
is "env command"                   ask $D Bash "env -i PATH=/usr/bin pod trade send $PLAN"
is "absolute path"                 ask $D Bash "/Users/me/.local/bin/pod trade send $PLAN"
is "quoted path"                   ask $D Bash '"$HOME/.local/bin/pod" trade send '"$PLAN"
is "bash -c double quotes"         ask $D Bash "bash -c \"pod trade send $PLAN\""
is "sh -c single quotes"           ask $D Bash "sh -c 'pod trade send $PLAN'"
is "zsh -lc"                       ask $D Bash "zsh -lc 'cd /tmp; pod trade send $PLAN'"
is "quotes inside words"           ask $D Bash "p''od tr\"\"ade se'n'd $PLAN"
is "command in a variable"         ask $D Bash "x=pod; \$x trade send $PLAN"
is "background and nohup"         ask $D Bash "nohup pod trade send $PLAN &"
is "xargs"                         ask $D Bash "echo $PLAN | xargs pod trade send"
is "on a new line"                 ask $D Bash $'pod status\npod trade send '"$PLAN"
is "heredoc into a script"         ask $D Bash $'cat > /tmp/go.sh <<EOF\npod trade send '"$PLAN"$'\nEOF\nbash /tmp/go.sh'
is "upper case"                    ask $D Bash "POD TRADE SEND $PLAN"
is "the script directly"           ask $D Bash "/repo/cli/libexec/trade.sh send $PLAN"
is "the script with POD_CLI"       ask $D Bash "POD_CLI=1 /repo/cli/libexec/trade.sh send $PLAN"
is "the script's --send"           ask $D Bash "POD_CLI=1 cli/libexec/trade.sh buy nvda 1 --price 1 --send"
is "any POD_CLI=1 use"             ask $D Bash "export POD_CLI=1; ./x.sh"
is "wallet.sh send"                ask $D Bash "POD_CLI=1 cli/libexec/wallet.sh send 0x50d0000000000000000000000000000000000002 'cancel(bytes32,bytes32,uint128)'"
is "setup with --yes"              ask $D Bash "pod setup --keystore dev --yes"
is "setup test --yes"              ask $D Bash "pod setup test --yes"
is "test-transaction.sh --yes"     ask $D Bash "POD_CLI=1 cli/libexec/test-transaction.sh --yes"
is "Monitor tool"                  ask $D Monitor "pod trade send $PLAN"
is "PowerShell tool"               ask $D PowerShell "pod trade send $PLAN"
reason_has "the question shows the plan" 'buy 0\.5 NVDA perp at \$150.*value \$75.*fee \$0\.03.*margin \$3\.75.*rounded' $D Bash "pod trade send $PLAN"
reason_has "an unknown plan still asks"  'sends a transaction from your pod wallet' $D Bash "pod trade send p00000000"

# Words that only read like a send pass: trade, setup and wallet count only after pod or a stand-in
is "commit message with trade send" none $D Bash "git commit -m 'trade send fix'"
is "commit message, --send flag"   none $D Bash "git commit -m \"add --send to the trade form\""
is "npm setup with --yes"          none $D Bash "npm run setup -- --yes"
is "another project's setup.sh"    none $D Bash "./setup.sh --yes"
is "grep for trade send"           none $D Bash "grep -rn 'trade send' docs/"
is "echo wallet send"              none $D Bash "echo wallet send"
# ...while every way of standing in for pod still asks
is "alias for pod"                 ask $D Bash "alias p=pod; p trade send $PLAN"
is "function around pod"           ask $D Bash "f() { pod \"\$@\"; }; f trade send $PLAN"
is "pod built by substitution"     ask $D Bash "\$(printf p)od trade send $PLAN"
is "pod built by backticks"        ask $D Bash "\`echo pod\` trade send $PLAN"
is "\${var} for pod"               ask $D Bash "P=pod; \${P} trade send $PLAN"
is "the setup script by path"      ask $D Bash "POD_CLI=1 /repo/cli/libexec/setup.sh --keystore dev --yes"
is "commit message naming pod asks" ask $D Bash "git commit -m 'pod trade send fix'"

# The prompt is the only question: it must say what is sent
cat > "$H/plans/p00000002.json" <<'EOF'
{"plan_id": "p00000002", "summary": "buy 0.066361 NVDA perp at market, no worse than $153.7",
 "preview": {"order_value_usd": "10.19", "value_at_current_price_usd": "9.99", "fee_usd": "0.0045",
             "margin_needed_usd": "0.51", "free_margin_after_usd": "95.2"},
 "notes": ["size 0.066361 = $10 at $150.69 (the current price)", "worst price $153.7: the current price $150.69 plus 2%"]}
EOF
reason_has "market order: value now and worst case" 'Send this trade from your pod wallet\? buy 0\.066361 NVDA perp at market.*Value about \$9\.99 at the current price, at most \$10\.19 at the worst price\. Fee \$0\.0045\. Margin \$0\.51, free margin after \$95\.2\.' $D Bash "pod trade send p00000002"
reason_has "market order: every note"    'Note: size 0\.066361 = \$10 at \$150\.69.*Note: worst price \$153\.7.*Approve to send it; deny and nothing is sent' $D Bash "pod trade send p00000002"
reason_has "setup test says what it sends" 'setup test transaction.*cannot fill.*two real transactions' $D Bash "pod setup test --yes"
reason_has "one-step send shows the command" 'Command: pod trade buy NVDA 1 --price 150 --send' $D Bash "pod trade buy NVDA 1 --price 150 --send"

# Switching approval off always asks
is "approval auto asks"            ask $D Bash "pod settings set approval auto"
is "approval=auto asks"            ask $D Bash "pod settings set approval=auto"
is "approval auto via the script"  ask $D Bash "POD_CLI=1 cli/libexec/profile.sh set approval auto"
reason_has "the question says what auto means" 'without asking you' $D Bash "pod settings set approval auto"

# pod's own files and the wallet itself always ask
is "reading the profile file"      ask $D Bash "cat ~/.config/pod-plugin/profile.json"
is "editing the profile with jq"   ask $D Bash "jq '.settings.approval = \"auto\"' ~/.config/pod-plugin/profile.json > /tmp/p && mv /tmp/p ~/.config/pod-plugin/profile.json"
is "another POD_PLUGIN_HOME"       ask $D Bash "POD_PLUGIN_HOME=/tmp/fake pod trade send $PLAN"
is "keystore folder"               ask $D Bash "ls ~/.foundry/keystores"
is "Keychain password"             ask $D Bash "security find-generic-password -s foundry-keystore -a dev -w"
is "cast send"                     ask $D Bash "cast send 0x50d0000000000000000000000000000000000002 'cancel(bytes32,bytes32,uint128)' 0x1 0x2 3"
is "cast mktx"                     ask $D Bash "cast mktx 0x50d0 'f()' --account dev"
is "raw transaction with curl"     ask $D Bash "curl -X POST https://staging-rpc.podtestnet.dev -d '{\"method\":\"eth_sendRawTransaction\"}'"
is "cast read passes"              none $D Bash "cast keccak hello"

# File tools
is "a script that sends asks"      ask $D Write "pod trade send $PLAN" "/tmp/go.sh"
is "an edit that sends asks"       ask $D Edit "pod trade send $PLAN" "/tmp/go.py"
is "a multi-edit that sends asks"  ask $D MultiEdit "pod trade send $PLAN" "/tmp/go"
is "docs that name a send pass"    none $D Write "Run pod trade send PLAN_ID to send." "/repo/README.md"
is "writing the profile asks"      ask $D Write '{"settings": {"approval": "auto"}}' "$H/profile.json"
is "writing a plan asks"           ask $D Edit '"summary": "x"' "$H/plans/$PLAN.json"
is "approval auto in a json file"  ask $D Edit '"approval": "auto"' "/tmp/settings.json"
is "an ordinary file passes"       none $D Write "hello" "/tmp/hello.sh"

# Permission modes
is "mode acceptEdits asks"         ask acceptEdits Bash "pod trade send $PLAN"
is "mode auto asks"                ask auto Bash "pod trade send $PLAN"
is "mode plan asks"                ask plan Bash "pod trade send $PLAN"
is "mode bypassPermissions denies" deny bypassPermissions Bash "pod trade send $PLAN"
is "mode dontAsk denies"           deny dontAsk Bash "pod trade send $PLAN"
is "bypass: approval auto denies"  deny bypassPermissions Bash "pod settings set approval auto"
is "bypass: reading passes"        none bypassPermissions Bash "pod markets"
is "no mode field asks"            ask "" Bash "pod trade send $PLAN"
reason_has "a deny says why"       'cannot ask the person.*Nothing was run' bypassPermissions Bash "pod trade send $PLAN"

# The approval setting
approval auto
is "auto: send passes"             none $D Bash "pod trade send $PLAN"
is "auto: --send passes"           none $D Bash "pod trade buy NVDA 1 --price 1 --send"
is "auto: setup --yes passes"      none $D Bash "pod setup test --yes"
is "auto: bypass send passes"      none bypassPermissions Bash "pod trade send $PLAN"
is "auto: approval auto still asks" ask $D Bash "pod settings set approval auto"
is "auto: other home still asks"   ask $D Bash "POD_PLUGIN_HOME=/tmp/fake pod trade send $PLAN"
is "auto: cast send still asks"    ask $D Bash "cast send 0x1 'f()'"
approval none
is "not set up: send asks"         ask $D Bash "pod trade send $PLAN"
approval broken
is "broken profile: send asks"     ask $D Bash "pod trade send $PLAN"
approval ask

# Robustness of the hook itself
out=$(printf 'not json pod trade send %s' "$PLAN" | "$HOOK" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)
if [ "$out" = ask ]; then pass=$((pass+1)); echo "ok   input that is not JSON: asks"; else failed=$((failed+1)); echo "FAIL input that is not JSON: $out"; fi
nojq="$(mktemp -d)"
for t in bash cat grep tr sed head printf env; do p=$(command -v "$t" 2>/dev/null) && [ -x "$p" ] && ln -s "$p" "$nojq/$t"; done
in=$(jq -nc --arg c "pod trade send $PLAN" '{permission_mode: "default", tool_name: "Bash", tool_input: {command: $c}}')
out=$(printf '%s' "$in" | PATH="$nojq" "$HOOK")
if printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null 2>&1; then pass=$((pass+1)); echo "ok   without jq: asks"
else failed=$((failed+1)); echo "FAIL without jq: $out"; fi
in=$(jq -nc --arg c "pod trade send $PLAN" '{permission_mode: "bypassPermissions", tool_name: "Bash", tool_input: {command: $c}}')
out=$(printf '%s' "$in" | PATH="$nojq" "$HOOK")
if printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then pass=$((pass+1)); echo "ok   without jq, bypass: denies"
else failed=$((failed+1)); echo "FAIL without jq, bypass: $out"; fi
rm -rf "$nojq"
start=$(date +%s)
for _ in $(seq 1 50); do printf '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' | "$HOOK" >/dev/null; done
took=$(( $(date +%s) - start ))
if [ "$took" -le 5 ]; then pass=$((pass+1)); echo "ok   50 unrelated commands in ${took}s"; else failed=$((failed+1)); echo "FAIL 50 unrelated commands took ${took}s"; fi

# The hook is declared the way Claude Code reads it
J="$(dirname "$HOOK")/hooks.json"
if jq -e '.hooks.PreToolUse[0] | (.matcher | split("|") | index("Bash") and index("Write")) and (.hooks[0].command | test("CLAUDE_PLUGIN_ROOT")) and .hooks[0].onFailure == "block"' "$J" >/dev/null; then
  pass=$((pass+1)); echo "ok   hooks.json declares the guard"
else failed=$((failed+1)); echo "FAIL hooks.json"; fi
[ -x "$HOOK" ] && { pass=$((pass+1)); echo "ok   the hook is executable"; } || { failed=$((failed+1)); echo "FAIL the hook is not executable"; }

echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
