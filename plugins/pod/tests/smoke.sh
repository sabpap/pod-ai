#!/usr/bin/env bash
# Read-only smoke test of the setup scripts against pod staging. Sends nothing.
# Uses a throwaway profile folder and a throwaway, unfunded private key, so the real profile and
# wallets are never touched.
#
# Usage: plugins/pod/tests/smoke.sh

set -uo pipefail
S="$(cd "$(dirname "$0")/../scripts" && pwd)"
export POD_PLUGIN_HOME="$(mktemp -d)"
trap 'rm -rf "$POD_PLUGIN_HOME"' EXIT

pass=0; failed=0
check() {   # check NAME JQ_EXPR COMMAND...
  local name="$1" expr="$2"; shift 2
  local out; out=$("$@" 2>/dev/null)
  if echo "$out" | jq -e "$expr" >/dev/null 2>&1; then pass=$((pass+1)); echo "ok   $name"
  else failed=$((failed+1)); echo "FAIL $name: $out"; fi
}

export SMOKE_KEY="$(cast wallet new --json | jq -r '.data | if type == "array" then .[0] else . end | .private_key')"

check "tools present"             '.ok'                                   "$S/check-tools.sh"
check "network is staging"        '.ok and .chain_id == 129302'           "$S/check-network.sh"
check "wallet list answers"       '.ok and (.keystores | type == "array")' "$S/list-wallets.sh"
check "no profile at start"       '.connected == false'                   "$S/profile.sh" show
check "unset variable refused"    '.ok == false and .step == "wallet"'    "$S/setup.sh" --env SMOKE_NOT_SET
check "bad key refused"           '.ok == false and .step == "wallet"'    env SMOKE_BAD=xyz "$S/setup.sh" --env SMOKE_BAD
check "missing keystore refused"  '.ok == false and .step == "wallet"'    "$S/setup.sh" --keystore smoke-no-such-wallet
check "unfunded key is read-only" '.ok and .level == "connected, read-only"' "$S/setup.sh" --env SMOKE_KEY
check "profile holds no key"      '.wallet.env_var == "SMOKE_KEY"'        "$S/profile.sh" show
if grep -q "${SMOKE_KEY#0x}" "$POD_PLUGIN_HOME/profile.json"; then failed=$((failed+1)); echo "FAIL key found in profile"; else pass=$((pass+1)); echo "ok   key not in profile file"; fi
check "unfunded test refused"     '.ok == false and .step == "test"'      "$S/test-transaction.sh" --dry-run
check "disconnect"                '.disconnected'                         "$S/profile.sh" delete
check "send refused when not set up" '.ok == false'                       "$S/wallet.sh" send 0x0 "f()"

# No password file may be left behind. Needs a keystore with a Keychain password; skipped otherwise.
ks=$("$S/list-wallets.sh" | jq -r '[.keystores[] | select(.keychain_password)][0].name // empty')
if [ -n "$ks" ]; then
  tmp="$(mktemp -d)"
  TMPDIR="$tmp" "$S/wallet.sh" --keystore "$ks" address >/dev/null
  TMPDIR="$tmp" "$S/wallet.sh" --keystore "$ks" sign-message smoke >/dev/null
  left=$(ls -A "$tmp" | wc -l | tr -d ' ')
  rm -rf "$tmp"
  if [ "$left" = "0" ]; then pass=$((pass+1)); echo "ok   no password file left ($ks)"
  else failed=$((failed+1)); echo "FAIL $left password file(s) left behind ($ks)"; fi
else
  echo "skip no password file left (no keystore with a Keychain password)"
fi

echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
