#!/usr/bin/env bash
# Install or remove the pod command: a symlink to cli/pod in a bin folder on PATH.
#
# Usage:
#   cli/install.sh                  link pod into ~/.local/bin
#   cli/install.sh --bin DIR        link it into DIR instead (or set POD_BIN_DIR)
#   cli/install.sh --uninstall      remove the link (only if it points to this pod)
#
# It changes nothing else: the profile and settings stay in ~/.config/pod-plugin.

set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POD="$HERE/pod"
BIN="${POD_BIN_DIR:-$HOME/.local/bin}"
action=install

while [ $# -gt 0 ]; do
  case "$1" in
    --bin) [ -n "${2:-}" ] || { echo "--bin needs a folder." >&2; exit 2; }; BIN="$2"; shift 2 ;;
    --uninstall) action=uninstall; shift ;;
    -h|--help) sed -n 's/^# \{0,1\}//; 2,9p' "$0"; exit 0 ;;
    *) echo "Unknown option $1. Use --bin DIR or --uninstall." >&2; exit 2 ;;
  esac
done

LINK="$BIN/pod"

if [ "$action" = uninstall ]; then
  if [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$POD" ]; then
    rm "$LINK"; echo "Removed $LINK."
  elif [ -e "$LINK" ] || [ -L "$LINK" ]; then
    echo "$LINK is not a link to $POD, so it was left alone." >&2; exit 1
  else
    echo "pod was not installed in $BIN."
  fi
  exit 0
fi

missing=""
for t in jq curl bc cast; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done

mkdir -p "$BIN"
if [ -e "$LINK" ] && ! [ -L "$LINK" ]; then
  echo "$LINK exists and is not a link; remove it first." >&2; exit 1
fi
ln -sfn "$POD" "$LINK"
echo "Linked $LINK -> $POD ($("$LINK" --version))."
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo "Note: $BIN is not on your PATH. Add it, for example: export PATH=\"$BIN:\$PATH\"" ;;
esac
[ -z "$missing" ] || echo "Note: pod also needs:$missing. On a Mac: brew install foundry jq (curl and bc come with macOS)."
command -v node >/dev/null 2>&1 || echo "Note: pod live needs Node.js 22 or later: brew install node."
echo "Next: pod status, then pod setup to connect a wallet."
