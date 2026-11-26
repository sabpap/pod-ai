#!/usr/bin/env bash
# Setup step 1: are the tools pod needs installed? Run as: pod setup tools
# Writes its JSON by hand, because jq itself may be the missing tool.

set -uo pipefail
if [ "${POD_CLI:-}" != 1 ]; then
  echo '{"ok": false, "step": "usage", "error": "This script runs only through the pod command.", "fix": "Run pod help to see the commands."}'
  exit 2
fi

missing=""
for t in cast jq curl bc; do
  command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
# The macOS Keychain tool is only needed for keystore wallets.
has_security=false
command -v security >/dev/null 2>&1 && has_security=true

# Node.js 22 or later is only needed for live updates (pod live); everything else works without it.
live_updates=false
major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
[ "$major" -ge 22 ] 2>/dev/null && live_updates=true

if [ -z "$missing" ]; then
  note=""
  $live_updates || note=", \"note\": \"Live updates need Node.js 22 or later: brew install node. Everything else works without it.\""
  echo "{\"ok\": true, \"tools\": [\"cast\", \"jq\", \"curl\", \"bc\"], \"keychain\": $has_security, \"live_updates\": $live_updates$note}"
  exit 0
fi

fix=""
case "$missing" in *cast*) fix="brew install foundry";; esac
case "$missing" in *jq*) fix="${fix:+$fix && }brew install jq";; esac
case "$missing" in *curl*|*bc*) fix="${fix:+$fix && }install curl and bc with your system's package manager";; esac
list=$(echo "$missing" | sed -e 's/^ //' -e 's/ /", "/g')
echo "{\"ok\": false, \"step\": \"tools\", \"error\": \"Missing: $(echo "$missing" | sed 's/^ //').\", \"missing\": [\"$list\"], \"fix\": \"$fix\"}"
exit 1
