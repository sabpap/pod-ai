# Shared by run-all.sh and run-extra.sh. Expects: HERE, WT, STATE, POD, branch, label, LOG.
# The reset uses the pod command from the 4-cli worktree with its own state folder, so it does not
# touch the state the branch under test built.

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

account_value() { pod_reset account overview | jq -r '.data.account_value_usd'; }

# Memory. Claude Code keeps one memory folder per repository, and git worktrees share it: a memory
# saved in one branch's session is read by every other branch's session, and by the user's own
# sessions in the main checkout. So after each run, whatever the run added or changed is copied next
# to the run's results, and each such file is put back as it was when the script started.
MEM="$HOME/.claude/projects/$(cd "$(git -C "$WT/$branch" rev-parse --git-common-dir)/.." && pwd | tr '/.' '--')/memory"
MEM_BEFORE=$(mktemp -d); mkdir -p "$MEM"; cp -R "$MEM/." "$MEM_BEFORE/"
memory_files() { (cd "$MEM" && for f in *; do [ -f "$f" ] && ! cmp -s "$f" "$MEM_BEFORE/$f" && printf '%s ' "$f"; done); }
stash_memory() {   # stash_memory NAME
  local f
  for f in $(memory_files); do
    mkdir -p "$HERE/results/$label/$1-memory"; cp "$MEM/$f" "$HERE/results/$label/$1-memory/"
    if [ -f "$MEM_BEFORE/$f" ]; then cp "$MEM_BEFORE/$f" "$MEM/$f"; else rm -f "$MEM/$f"; fi
  done
  return 0
}
