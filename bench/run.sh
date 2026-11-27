#!/usr/bin/env bash
# Runs one benchmark case on one branch, headless, and records what the agent did.
#
#   bench/run.sh BRANCH CASE [RUN_NUMBER]
#   bench/run.sh 1-raw B        one run of case B on branch 1-raw
#   bench/run.sh 4-cli C 2      the second run of case C on branch 4-cli
#   bench/run.sh summary        one table of every run recorded so far
#
# BRANCH is 1-raw, 2-manual, 3-plugin, 4-cli, or 4-cli-noskill (the pod command with no skill, case I).
# 3-plugin-auto and 4-cli-auto are the same branches, recorded apart, for runs made with the approval
# setting switched to "auto" (bench/run-all.sh BRANCH auto does the switch).
# 3-plugin-hook is 3-plugin with the approval hook of 4-cli loaded beside it, as a second plugin.
#
# A prompt in cases.tsv can hold several turns, separated by " ||| ". Each later turn resumes the same
# session, as a person answering would. The summary adds the turns up.
# Each branch is a git worktree in $POD_BENCH_WORKTREES (default: ../pod-ai-variants next to this repo).
# Each branch uses its own wallet, a Foundry keystore called pod-BRANCH, and its own state folder.
#
# The session is clean: no user settings, no user plugins, no MCP servers. Only the branch under test
# is loaded. Every tool is allowed, so the only thing that can stop a trade is the branch itself.
# The model is the same for every run.
#
# It SENDS REAL TRANSACTIONS on pod staging with the branch's wallet when the agent decides to.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WT="${POD_BENCH_WORKTREES:-$(dirname "$ROOT")/pod-ai-variants}"
MODEL="${POD_BENCH_MODEL:-claude-opus-4-6}"
OUT="$HERE/results"

summary() {
  printf 'branch\tcase\trun\tdone\tturns\ttool_calls\tseconds\tcost_usd\tdenied\tsends\n'
  for f in "$OUT"/*/*.summary.json; do
    [ -f "$f" ] || continue
    jq -r '[.branch, .case, .run, .finished, .turns, .tool_calls, .seconds, .cost_usd, .permission_denials, .send_attempts] | @tsv' "$f"
  done | sort
}
[ "${1:-}" = summary ] && { summary; exit 0; }

branch="${1:?branch}"; case_id="${2:?case}"; run="${3:-1}"

row=$(awk -F'\t' -v id="$case_id" '$1 == id' "$HERE/cases.tsv")
[ -n "$row" ] || { echo "No case $case_id in cases.tsv" >&2; exit 2; }
mode=$(echo "$row" | cut -f2); timeout_s=$(echo "$row" | cut -f4); prompt=$(echo "$row" | cut -f5)
[ "$mode" = auto ] || { echo "Case $case_id is run by hand: $prompt" >&2; exit 2; }

real="${branch%-noskill}"; real="${real%-auto}"; real="${real%-hook}"
prompt="${prompt//\{wallet\}/pod-$real}"
dir="$WT/$real"
[ -d "$dir" ] || { echo "No worktree at $dir. Create it: git worktree add $dir $real" >&2; exit 2; }

# The branch's own wallet and state, apart from every other branch and from the user's own profile.
export POD_KEYSTORE="pod-$real"
export POD_PLUGIN_HOME="${POD_BENCH_STATE:-$HOME/.config/pod-bench}/$real"
unset POD_PRIVATE_KEY
mkdir -p "$POD_PLUGIN_HOME"

args=(--model "$MODEL" --output-format stream-json --verbose
      --setting-sources project --strict-mcp-config
      --allowedTools "Bash,Read,Write,Edit,Glob,Grep,WebFetch,WebSearch,Skill,Monitor")
work="$dir"
case "$branch" in
  1-raw|2-manual) ;;                                   # the skill loads from the worktree's .claude/skills
  3-plugin|3-plugin-auto) args+=(--plugin-dir "$dir/plugins/pod") ;;
  4-cli|4-cli-auto) args+=(--plugin-dir "$dir/plugins/pod"); export PATH="$dir/cli:$PATH" ;;
  3-plugin-hook)                                       # the hook alone, copied from the 4-cli worktree
    hook=$(mktemp -d); mkdir -p "$hook/.claude-plugin"; cp -R "$WT/4-cli/plugins/pod/hooks" "$hook/hooks"
    echo '{"name": "pod-guard", "version": "1.0.0", "description": "The approval hook of 4-cli, alone."}' > "$hook/.claude-plugin/plugin.json"
    args+=(--plugin-dir "$dir/plugins/pod" --plugin-dir "$hook") ;;
  4-cli-noskill)                                       # the command alone, from an empty folder
    export PATH="$dir/cli:$PATH"; work=$(mktemp -d); args+=(--disallowedTools "Skill") ;;
  *) echo "Unknown branch $branch" >&2; exit 2 ;;
esac

mkdir -p "$OUT/$branch"
log="$OUT/$branch/$case_id-$run.jsonl"
start=$(date +%s)
# `command claude` skips any shell wrapper around claude. A run that hits the time limit is recorded as not finished.
: > "$log"; : > "$log.err"; session=""
rest="$prompt"
while [ -n "$rest" ]; do
  case "$rest" in *" ||| "*) turn="${rest%%" ||| "*}"; rest="${rest#*" ||| "}" ;; *) turn="$rest"; rest="" ;; esac
  resume=(); [ -n "$session" ] && resume=(--resume "$session")
  echo '{"type": "bench_turn"}' >> "$log"   # marks where a turn starts: cost is counted per turn
  ( cd "$work" && perl -e 'alarm shift; exec @ARGV' "$timeout_s" command claude -p "$turn" ${resume[@]+"${resume[@]}"} "${args[@]}" ) >> "$log" 2>> "$log.err" || true
  session=$(jq -rs '[.[] | select(.type == "result") | .session_id] | last // empty' "$log")
  [ -n "$session" ] || break
done
secs=$(( $(date +%s) - start ))

# What the agent did, from the transcript. send_attempts counts commands that would move money:
# the branch's own send command, or a raw transaction.
jq -s --arg b "$branch" --arg c "$case_id" --arg r "$run" --argjson s "$secs" '
  ([.[] | select(.type == "assistant") | .message.content[]? | select(.type == "tool_use")]) as $calls
  | [.[] | select(.type == "result")] as $all | ($all | last) as $res
  | { branch: $b, case: $c, run: ($r | tonumber),
      finished: ($res != null and ($res.is_error | not)),
      turns: ([$all[].num_turns // 0] | add),
      tool_calls: ($calls | length),
      tools: ($calls | group_by(.name) | map({key: .[0].name, value: length}) | from_entries),
      seconds: $s,
      cost_usd: (reduce .[] as $e ({sum: 0, cur: 0};
                   if $e.type == "bench_turn" then {sum: (.sum + .cur), cur: 0}
                   elif $e.type == "result" then .cur = ([.cur, ($e.total_cost_usd // 0)] | max) else . end) | .sum + .cur),
      permission_denials: ([$all[].permission_denials // [] | length] | add // 0),
      sessions_turns: ($all | length),
      send_attempts: ([$calls[] | select(.name == "Bash") | .input.command // ""
                       | select(test("trade(\\.sh)? +send|--send|eth_sendRawTransaction|cast +(send|publish)|pod-send\\.sh(?!.*(--dry-run|--check|--help))"))] | length),
      answer: ([$all[].result // ""] | join("\n\n--- next turn ---\n\n")) }' "$log" > "$OUT/$branch/$case_id-$run.summary.json"

jq '{branch, case, run, finished, turns, tool_calls, seconds, cost_usd, permission_denials, send_attempts}' "$OUT/$branch/$case_id-$run.summary.json"
echo "Answer and transcript: $OUT/$branch/$case_id-$run.summary.json, $log" >&2
