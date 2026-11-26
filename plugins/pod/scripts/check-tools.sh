#!/usr/bin/env bash
# Setup step 1: are the tools the plugin needs installed?
# Usage: check-tools.sh
# Writes its JSON by hand, because jq itself may be the missing tool.

set -uo pipefail

missing=""
for t in cast jq curl bc; do
  command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
# The macOS Keychain tool is only needed for keystore wallets.
has_security=false
command -v security >/dev/null 2>&1 && has_security=true

if [ -z "$missing" ]; then
  echo "{\"ok\": true, \"tools\": [\"cast\", \"jq\", \"curl\", \"bc\"], \"keychain\": $has_security}"
  exit 0
fi

fix=""
case "$missing" in *cast*) fix="brew install foundry";; esac
case "$missing" in *jq*) fix="${fix:+$fix && }brew install jq";; esac
case "$missing" in *curl*|*bc*) fix="${fix:+$fix && }install curl and bc with your system's package manager";; esac
list=$(echo "$missing" | sed -e 's/^ //' -e 's/ /", "/g')
echo "{\"ok\": false, \"step\": \"tools\", \"error\": \"Missing: $(echo "$missing" | sed 's/^ //').\", \"missing\": [\"$list\"], \"fix\": \"$fix\"}"
exit 1
