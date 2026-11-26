#!/usr/bin/env bash
# cli/install.sh in a throwaway bin folder: install, run pod through the link, uninstall. Never touches
# ~/.local/bin. No network.
# Usage: cli/tests/install.sh

set -uo pipefail
CLI="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
BIN="$T/bin"

pass=0; failed=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { failed=$((failed+1)); echo "FAIL $1"; }

out=$("$CLI/install.sh" --bin "$BIN"); code=$?
[ $code = 0 ] && ok "install exits 0" || bad "install: exit $code: $out"
[ -L "$BIN/pod" ] && [ "$(readlink "$BIN/pod")" = "$CLI/pod" ] && ok "pod is a link to cli/pod" || bad "no link at $BIN/pod"
echo "$out" | grep -q "is not on your PATH" && ok "warns that the folder is not on PATH" || bad "no PATH note: $out"
[ "$(PATH="$BIN:$PATH" pod --version)" = "$("$CLI/pod" --version)" ] && ok "pod runs through the link" || bad "pod through the link"
PATH="$BIN:$PATH" pod status --help | head -1 | grep -q '^pod status:' && ok "the link finds libexec" || bad "the link does not find libexec"
out=$(cd "$T" && PATH="$BIN:$PATH" POD_PLUGIN_HOME="$T/home" pod settings); echo "$out" | jq -e '.settings.approval == "ask"' >/dev/null && ok "pod works from another folder" || bad "pod from another folder: $out"
out=$(PATH="$BIN:$PATH" "$CLI/install.sh" --bin "$BIN"); [ $? = 0 ] && ! echo "$out" | grep -q "not on your PATH" && ok "install again: no PATH note when on PATH" || bad "install again: $out"
POD_BIN_DIR="$T/bin2" "$CLI/install.sh" >/dev/null && [ -L "$T/bin2/pod" ] && ok "POD_BIN_DIR sets the folder" || bad "POD_BIN_DIR"

mkdir -p "$T/bin3"; echo "not pod" > "$T/bin3/pod"
"$CLI/install.sh" --bin "$T/bin3" >/dev/null 2>&1; code=$?
[ $code = 1 ] && [ "$(cat "$T/bin3/pod")" = "not pod" ] && ok "a file that is not a link is left alone" || bad "overwrote a file (exit $code)"
"$CLI/install.sh" --bin "$T/bin3" --uninstall >/dev/null 2>&1; code=$?
[ $code = 1 ] && [ -f "$T/bin3/pod" ] && ok "uninstall leaves another pod alone" || bad "uninstall removed another pod (exit $code)"

out=$("$CLI/install.sh" --bin "$BIN" --uninstall); code=$?
[ $code = 0 ] && ! [ -e "$BIN/pod" ] && ! [ -L "$BIN/pod" ] && ok "uninstall removes the link" || bad "uninstall: exit $code, $out"
out=$("$CLI/install.sh" --bin "$BIN" --uninstall); code=$?
[ $code = 0 ] && echo "$out" | grep -q "was not installed" && ok "uninstall twice is fine" || bad "uninstall twice: $out"
[ -f "$CLI/pod" ] && ok "uninstall keeps cli/pod" || bad "cli/pod is gone"
"$CLI/install.sh" --nonsense >/dev/null 2>&1; [ $? = 2 ] && ok "unknown option: exit 2" || bad "unknown option"
"$CLI/install.sh" --help | grep -q -- '--uninstall' && ok "install --help" || bad "install --help"

echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
