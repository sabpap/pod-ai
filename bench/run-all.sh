#!/usr/bin/env bash
# Runs every automatic case three times on one branch, in order, and resets the wallet between runs.
#
#   bench/run-all.sh BRANCH          BRANCH is 1-raw, 2-manual, 3-plugin or 4-cli
#   bench/run-all.sh BRANCH auto     3-plugin or 4-cli only: the trade cases again with the approval
#                                    setting on "auto", recorded as BRANCH-auto. Run it after the
#                                    first form: it needs the connected, proven wallet.
#
# Run the four branches side by side, one process each: they use different wallets.
#
# Order of work:
#   1. Case A three times, each from an empty state folder.
#   2. On 3-plugin and 4-cli, the wallet's test transaction is sent once, as the person's "approve"
#      to the question case A ends on. Later cases then start from a proven wallet.
#   3. Cases B, C, D, F and G three times each (and case I on 4-cli, with no skill).
#      After every run: cancel all orders and triggers, close all perp positions.
#
# The reset uses the pod command from the 4-cli worktree with its own state folder, so it does not
# touch the state the branch under test built. Its output goes to bench/results/BRANCH/reset.log.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WT="${POD_BENCH_WORKTREES:-$(dirname "$(dirname "$HERE")")/pod-ai-variants}"
STATE="${POD_BENCH_STATE:-$HOME/.config/pod-bench}"
branch="${1:?branch}"
POD="$WT/4-cli/cli/pod"
label="$branch"; [ "${2:-}" = auto ] && label="$branch-auto"
mkdir -p "$HERE/results/$label"
LOG="$HERE/results/$label/reset.log"

pod_reset() { POD_KEYSTORE="pod-$branch" POD_PLUGIN_HOME="$STATE/cleanup-$branch" "$POD" "$@"; }

send_plan() {   # reads a plan on stdin, sends it unless there was nothing to do
  local plan id
  plan=$(cat); echo "$plan" | jq -c '{ok, summary, error}' >> "$LOG"
  id=$(echo "$plan" | jq -r '.plan_id // empty')
  [ -n "$id" ] && pod_reset trade send "$id" | jq -c '{ok, error}' >> "$LOG"
}

reset_wallet() {
  echo "== reset after $1 $(date -u +%H:%M:%S)" >> "$LOG"
  pod_reset setup show | jq -e '.connected == true' > /dev/null 2>&1 \
    || pod_reset setup --keystore "pod-$branch" --skip-test >> "$LOG" 2>&1
  pod_reset trade cancel-all | send_plan
  pod_reset account triggers | jq -r '.data[]?.order_id' | while read -r t; do
    pod_reset trade cancel-trigger "$t" | send_plan
  done
  sleep 3
  pod_reset account positions | jq -r '.data[]?.market' | while read -r m; do
    pod_reset trade close "$m" --band 5 | send_plan
  done
  sleep 5
  pod_reset account overview | jq -c '{left: .data}' >> "$LOG"
}

set_approval() {
  case "$branch" in
    3-plugin) POD_PLUGIN_HOME="$STATE/$branch" "$WT/3-plugin/plugins/pod/scripts/profile.sh" set approval "$1" ;;
    4-cli)    POD_PLUGIN_HOME="$STATE/$branch" "$POD" settings set approval "$1" ;;
    *) echo "Only 3-plugin and 4-cli have an approval setting." >&2; exit 2 ;;
  esac | jq -c '{ok, approval: .settings.approval}' >> "$LOG"
}

if [ "$label" != "$branch" ]; then
  set_approval auto
  for c in C D F G; do
    for run in 1 2 3; do
      [ -f "$HERE/results/$label/$c-$run.summary.json" ] && continue
      "$HERE/run.sh" "$label" "$c" "$run"
      reset_wallet "$c-$run"
    done
  done
  set_approval ask
  echo "done $label $(date -u +%H:%M:%S)" >> "$LOG"
  exit 0
fi

# 1. Setup, from nothing each time. Run 1 is kept if it is already recorded.
for run in 1 2 3; do
  [ -f "$HERE/results/$branch/A-$run.summary.json" ] && continue
  rm -rf "${STATE:?}/$branch"
  "$HERE/run.sh" "$branch" A "$run"
done

# 2. The person's "approve" for the wallet test.
case "$branch" in
  3-plugin) POD_PLUGIN_HOME="$STATE/$branch" "$WT/3-plugin/plugins/pod/scripts/test-transaction.sh" --yes >> "$LOG" 2>&1 ;;
  4-cli)    POD_PLUGIN_HOME="$STATE/$branch" "$POD" setup test --yes >> "$LOG" 2>&1 ;;
esac

# 3. The other cases.
cases="B C D F G"
for c in $cases; do
  for run in 1 2 3; do
    [ -f "$HERE/results/$branch/$c-$run.summary.json" ] && continue
    "$HERE/run.sh" "$branch" "$c" "$run"
    [ "$c" = B ] || reset_wallet "$c-$run"
  done
done
if [ "$branch" = 4-cli ]; then
  for run in 1 2 3; do
    [ -f "$HERE/results/4-cli-noskill/I-$run.summary.json" ] && continue
    "$HERE/run.sh" 4-cli-noskill I "$run"
  done
fi
echo "done $branch $(date -u +%H:%M:%S)" >> "$LOG"
