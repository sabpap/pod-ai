#!/usr/bin/env bash
# Convert pod's numbers exactly, both ways. No floating point anywhere: amounts are handled as digit
# strings and bc, so values past 64-bit integers and past double precision stay exact.
#
# Usage:
#   pod-number.sh from-pod VALUE...   pod's 10^18-scaled number (0x hex, decimal, signed) -> plain decimal
#   pod-number.sh to-pod DECIMAL...   plain decimal ("151.03", "-0.5") -> pod's 10^18-scaled integer
#   pod-number.sh int VALUE...        0x hex or decimal integer -> decimal integer, not scaled
#   pod-number.sh time MICROS...      microseconds since 1970 -> ISO-8601 UTC ("never" for 2^64 - 1)
#   pod-number.sh us TIME...          ISO-8601 UTC, a date (2026-11-26) or "now" -> microseconds
#
# Options:
#   --decimals N   scale for from-pod and to-pod (default 18)
#   --hex          to-pod prints 0x hex instead of decimal (unsigned values only)
#
# Prints one result per line. Anything it cannot convert exactly is an error (exit 1), never a guess.

set -euo pipefail
export BC_LINE_LENGTH=0

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "pod-number.sh: $1" >&2; exit 1; }

# int_of VALUE: any pod integer (0x hex, -0x hex, decimal, -decimal) as a decimal integer string.
int_of() {
  local v="$1" neg="" d
  case "$v" in -*) neg="-"; v="${v#-}" ;; +*) v="${v#+}" ;; esac
  case "$v" in
    0x*|0X*)
      v="${v:2}"
      [[ "$v" =~ ^[0-9a-fA-F]+$ ]] || return 1
      d=$(echo "ibase=16; $(echo "$v" | tr 'a-f' 'A-F')" | bc | tr -d '\\\n') ;;
    *)
      [[ "$v" =~ ^[0-9]+$ ]] || return 1
      d=$(echo "$v" | sed 's/^0*//'); d="${d:-0}" ;;
  esac
  [ "$d" = 0 ] && neg=""
  echo "$neg$d"
}

# scale_down INT N: a decimal integer divided by 10^N, exact, without trailing zeros.
scale_down() {
  local i="$1" n="$2" neg="" int frac
  case "$i" in -*) neg="-"; i="${i#-}" ;; esac
  if [ "$n" -eq 0 ]; then echo "$neg$i"; return; fi
  while [ "${#i}" -le "$n" ]; do i="0$i"; done
  int="${i:0:$(( ${#i} - n ))}"
  frac=$(echo "${i:$(( ${#i} - n ))}" | sed 's/0*$//')
  echo "$neg$int${frac:+.$frac}"
}

# scale_up DECIMAL N: a plain decimal times 10^N, exact. Fails on more than N decimals.
scale_up() {
  local v="$1" n="$2" neg="" int frac="" out
  [[ "$v" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || return 1
  case "$v" in -*) neg="-"; v="${v#-}" ;; esac
  int="${v%%.*}"
  case "$v" in *.*) frac="${v#*.}" ;; esac
  [ "${#frac}" -le "$n" ] || return 2
  while [ "${#frac}" -lt "$n" ]; do frac="${frac}0"; done
  out=$(echo "$int$frac" | sed 's/^0*//'); out="${out:-0}"
  [ "$out" = 0 ] && neg=""
  echo "$neg$out"
}

if date -u -d @0 +%s >/dev/null 2>&1; then GNU_DATE=true; else GNU_DATE=false; fi

secs_to_iso() {   # whole seconds since 1970 -> YYYY-MM-DDTHH:MM:SS
  if $GNU_DATE; then date -u -d "@$1" +%Y-%m-%dT%H:%M:%S; else date -u -r "$1" +%Y-%m-%dT%H:%M:%S; fi
}
iso_to_secs() {   # "YYYY-MM-DD HH:MM:SS" (UTC) -> whole seconds since 1970
  if $GNU_DATE; then date -u -d "$1" +%s; else date -j -u -f '%Y-%m-%d %H:%M:%S' "$1" +%s; fi
}

to_time() {
  local us s f
  us=$(int_of "$1") || die "'$1' is not a whole number of microseconds."
  [ "$us" = 18446744073709551615 ] && { echo never; return; }
  case "$us" in -*) die "'$1' is negative: not a time." ;; esac
  [ "${#us}" -le 17 ] || die "'$1' is too large to be a time in microseconds."
  case "${#us}" in
    10) die "'$1' looks like seconds, not microseconds. Multiply by 1000000, or check which unit the field uses." ;;
    13) die "'$1' looks like milliseconds, not microseconds. Multiply by 1000, or check which unit the field uses." ;;
  esac
  s=$(( us / 1000000 )); f=$(( us % 1000000 ))
  if [ "$f" -eq 0 ]; then echo "$(secs_to_iso "$s")Z"
  elif [ $(( f % 1000 )) -eq 0 ]; then printf '%s.%03dZ\n' "$(secs_to_iso "$s")" $(( f / 1000 ))
  else printf '%s.%06dZ\n' "$(secs_to_iso "$s")" "$f"; fi
}

to_us() {
  local t="$1" day hms frac="" s
  if [ "$t" = now ]; then echo $(( $(date +%s) * 1000000 )); return; fi
  [[ "$t" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]{1,6})?)?)?(Z|\+00:00)?$ ]] \
    || die "'$t' is not a UTC time. Use 2026-11-26, 2026-11-26T14:36:45Z, 2026-11-26T14:36:45.500Z or now."
  t="${t%Z}"; t="${t%+00:00}"
  day="${t%%T*}"; hms="00:00:00"
  case "$t" in *T*) hms="${t#*T}" ;; esac
  case "$hms" in *.*) frac="${hms#*.}"; hms="${hms%%.*}" ;; esac
  [ "${#hms}" -eq 5 ] && hms="$hms:00"
  s=$(iso_to_secs "$day $hms" 2>/dev/null) || die "'$1' is not a valid date or time."
  while [ "${#frac}" -lt 6 ]; do frac="${frac}0"; done
  echo $(( s * 1000000 + 10#$frac ))
}

# --- arguments ---------------------------------------------------------------------------------------

cmd="${1:-}"
case "$cmd" in ""|-h|--help|help) usage; exit 0 ;; esac
shift
decimals=18; hex=false; values=()
while [ $# -gt 0 ]; do
  case "$1" in
    --decimals) decimals="${2:-}"; shift 2 || die "--decimals needs a number." ;;
    --hex) hex=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) values+=("$1"); shift ;;
  esac
done
[[ "$decimals" =~ ^[0-9]+$ ]] && [ "$decimals" -le 77 ] || die "--decimals must be a whole number from 0 to 77."
[ "${#values[@]}" -gt 0 ] || die "give at least one value. See: pod-number.sh --help"

for v in "${values[@]}"; do
  case "$cmd" in
    from-pod)
      i=$(int_of "$v") || die "'$v' is not a pod number (0x hex or a decimal integer, optionally signed)."
      scale_down "$i" "$decimals" ;;
    to-pod)
      rc=0; i=$(scale_up "$v" "$decimals") || rc=$?
      [ "$rc" = 2 ] && die "'$v' has more than $decimals decimals, so it cannot be converted exactly. Round it to the market's step first."
      [ "$rc" = 0 ] || die "'$v' is not a plain decimal number such as 151.03, 0.5 or -2 (no commas, no exponent, no \$)."
      if $hex; then
        case "$i" in -*) die "--hex is for unsigned values; pod sends signed values as decimal strings." ;; esac
        echo "0x$(echo "obase=16; $i" | bc | tr -d '\\\n' | tr 'A-F' 'a-f')"
      else echo "$i"; fi ;;
    int)
      int_of "$v" || die "'$v' is not an integer (0x hex or decimal)." ;;
    time) to_time "$v" ;;
    us) to_us "$v" ;;
    *) die "unknown command '$cmd'. Use from-pod, to-pod, int, time or us. See: pod-number.sh --help" ;;
  esac
done
