#!/usr/bin/env bash
# The live listener against a fake pod WebSocket that drops the connection and then closes the stream
# the way pod does. Checks it resumes from the last round seen each time, with no gap and no repeat,
# and that a condition still ends it. Reads pod staging's REST API for the market names. Needs deno;
# skipped without it.
#
# Usage: cli/tests/live-reconnect.sh

set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
POD="$D/../pod"
command -v deno >/dev/null 2>&1 || { echo "skip live reconnect (deno is not installed)"; exit 0; }

export POD_PLUGIN_HOME="$(mktemp -d)"
port=$(( 20000 + RANDOM % 20000 ))
log="$POD_PLUGIN_HOME/server.log"
deno run --allow-net "$D/fake-pod-ws.ts" "$port" > "$log" 2>&1 &
server=$!
disown "$server" 2>/dev/null || true   # no "Terminated" line when it is stopped at the end
trap 'kill $server 2>/dev/null; rm -rf "$POD_PLUGIN_HOME"' EXIT
for _ in $(seq 1 50); do grep -q listening "$log" 2>/dev/null && break; sleep 0.1; done

out=$(POD_TEST_WS="ws://127.0.0.1:$port" "$POD" live book nvda --every 0 --until "best_bid > 199" --for 30s)

pass=0; failed=0
check() {   # check NAME JQ_EXPR INPUT
  if echo "$3" | jq -e -s "$2" >/dev/null 2>&1; then pass=$((pass+1)); echo "ok   $1"
  else failed=$((failed+1)); echo "FAIL $1"; echo "$3" | sed 's/^/     /'; fi
}
R() { echo $(( 1795710000000000 + $1 * 500000 )); }

check "starts watching"            '.[0].event == "watching"' "$out"
check "rounds 1-4 once each"       '[.[] | select(.best_bid and (.event | not)) | .time] == ["2026-11-26T16:20:00.500Z","2026-11-26T16:20:01Z","2026-11-26T16:20:01.500Z","2026-11-26T16:20:02Z"]' "$out"
check "reports the lost connection" 'any(.[]; .event == "notice" and (.message | test("lost")))' "$out"
check "reports catching up"        '[.[] | select(.event == "notice" and (.message | test("caught up")))] | length == 2' "$out"
check "reports pod closing it"     'any(.[]; .event == "notice" and (.message | test("closed the stream")))' "$out"
check "ends on the condition"      '.[-1].event == "condition met" and .[-1].best_bid == "200"' "$out"
srv=$(grep '"conn"' "$log")
check "first subscription is live" "map(select(.conn == 1))[0].since == null" "$srv"
check "reconnect resumes at round 3" "map(select(.conn == 2 and .sub == 1))[0].since == $(R 3)" "$srv"
check "stream close resumes at round 4" "map(select(.conn == 2 and .sub == 2))[0].since == $(R 4)" "$srv"
check "registry cleaned up"        '.[0] == 0' "$(ls "$POD_PLUGIN_HOME/live" | wc -l | tr -d ' ')"

echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
