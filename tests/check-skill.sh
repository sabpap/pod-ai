#!/usr/bin/env bash
# Offline checks of the skill itself: SKILL.md frontmatter, that every file it or a reference links to
# exists, that every reference is reachable from SKILL.md, that the scripts are executable and that the
# description names the kinds of request it must trigger on.
# Usage: tests/check-skill.sh

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SK="$ROOT/.claude/skills/pod"
pass=0; failed=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { failed=$((failed+1)); echo "FAIL $1${2:+: $2}"; }

[ -f "$SK/SKILL.md" ] && ok "SKILL.md exists" || { bad "SKILL.md exists"; exit 1; }

# --- frontmatter --------------------------------------------------------------------------------------
[ "$(sed -n 1p "$SK/SKILL.md")" = "---" ] && ok "frontmatter opens on line 1" || bad "frontmatter opens on line 1"
fm_end=$(awk 'NR > 1 && /^---$/ { print NR; exit }' "$SK/SKILL.md")
[ -n "$fm_end" ] && ok "frontmatter closes (line $fm_end)" || bad "frontmatter closes"
FM=$(sed -n "2,$(( fm_end - 1 ))p" "$SK/SKILL.md")
keys=$(echo "$FM" | sed -n 's/^\([a-z_-]*\):.*/\1/p' | sort | tr '\n' ' ')
[ "$keys" = "description name " ] && ok "frontmatter has exactly name and description" || bad "frontmatter keys" "$keys"
name=$(echo "$FM" | sed -n 's/^name: //p')
desc=$(echo "$FM" | sed -n 's/^description: //p')
[[ "$name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] && [ "${#name}" -le 64 ] && ok "name '$name' is lower case with hyphens, at most 64 characters" || bad "name format" "$name"
[ "$name" = "$(basename "$SK")" ] && ok "name matches the folder" || bad "name matches the folder"
[ -n "$desc" ] && [ "${#desc}" -le 1024 ] && ok "description is ${#desc} characters (at most 1024)" || bad "description length" "${#desc}"
case "$desc" in *"<"*|*">"*) bad "description has no angle brackets" ;; *) ok "description has no angle brackets" ;; esac
echo "$FM" | grep -q '^description: .*' && [ "$(echo "$FM" | grep -c '^description:')" = 1 ] && ok "description is one line" || bad "description is one line"
for w in balance positions orders markets prices "order book" watch buy sell cancel stop-loss take-profit trades "pod network"; do
  echo "$desc" | grep -qi -- "$w" && ok "description mentions '$w'" || bad "description mentions '$w'"
done
lines=$(wc -l < "$SK/SKILL.md" | tr -d ' ')
[ "$lines" -le 500 ] && ok "SKILL.md is $lines lines (short)" || bad "SKILL.md is long" "$lines"

# --- links and files ----------------------------------------------------------------------------------
for f in "$SK/SKILL.md" "$SK"/references/*.md; do
  dir=$(dirname "$f")
  for link in $(grep -o '\](\([^)#]*\)\(#[^)]*\)\?)' "$f" | sed 's/^](//; s/)$//' | grep -v '^https\?:' | sort -u); do
    path="${link%%#*}"; anchor="${link#*#}"; [ "$anchor" = "$link" ] && anchor=""
    target="$dir/$path"; [ -z "$path" ] && target="$f"
    if [ -f "$target" ]; then
      if [ -n "$anchor" ]; then
        # GitHub-style anchors: lower case, spaces to hyphens, punctuation dropped
        if grep '^#' "$target" | sed 's/^#* //' | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9 _-]//g; s/ /-/g' | grep -qx -- "$anchor"; then
          ok "$(basename "$f") → $link"
        else bad "$(basename "$f") → $link" "no such heading"; fi
      else ok "$(basename "$f") → $link"; fi
    else bad "$(basename "$f") → $link" "missing file"; fi
  done
done
for r in "$SK"/references/*.md; do
  grep -q "references/$(basename "$r")" "$SK/SKILL.md" && ok "SKILL.md links $(basename "$r")" || bad "SKILL.md links $(basename "$r")"
done
for s in pod-number.sh pod-send.sh; do
  grep -q "scripts/$s" "$SK/SKILL.md" && ok "SKILL.md names scripts/$s" || bad "SKILL.md names scripts/$s"
  [ -x "$SK/scripts/$s" ] && ok "scripts/$s is executable" || bad "scripts/$s is executable"
  "$SK/scripts/$s" --help >/dev/null 2>&1 && ok "scripts/$s --help works" || bad "scripts/$s --help"
done
n=$(ls "$SK/scripts" | wc -l | tr -d ' ')
[ "$n" = 2 ] && ok "exactly two scripts" || bad "exactly two scripts" "$n"

# --- nothing of the hybrid left -----------------------------------------------------------------------
for p in plugins specs .claude-plugin; do
  [ -e "$ROOT/$p" ] && bad "no $p/ in this branch" || ok "no $p/ in this branch"
done
if grep -rn -e 'CLAUDE_PLUGIN_ROOT' -e 'trade\.sh' -e 'account\.sh' -e 'markets\.sh' -e 'live\.sh' -e '/pod:' "$SK" >/dev/null; then
  bad "the skill does not point to the plugin's scripts or commands" "$(grep -rn -e CLAUDE_PLUGIN_ROOT -e 'trade\.sh' -e '/pod:' "$SK" | head -3)"
else ok "the skill does not point to the plugin's scripts or commands"; fi

echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
