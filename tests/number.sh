#!/usr/bin/env bash
# Offline tests of scripts/pod-number.sh. No network, no wallet.
# Usage: tests/number.sh
# Ported from the pod plugin's number tests (tests/units.sh on the 3-plugin branch), plus round trips
# and the edges of 64-bit integers and doubles.

set -uo pipefail
N="$(cd "$(dirname "$0")/.." && pwd)/.claude/skills/pod/scripts/pod-number.sh"

pass=0; failed=0
eq() {   # eq NAME GOT WANT
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"
  else failed=$((failed+1)); echo "FAIL $1: got '$2', want '$3'"; fi
}
refused() {   # refused NAME CMD...: the command must fail and print nothing on stdout
  local out
  if out=$("${@:2}" 2>/dev/null); then failed=$((failed+1)); echo "FAIL $1: accepted, printed '$out'"
  elif [ -n "$out" ]; then failed=$((failed+1)); echo "FAIL $1: refused but printed '$out'"
  else pass=$((pass+1)); echo "ok   $1"; fi
}

# from-pod: pod's 10^18-scaled numbers, hex or decimal, signed or not
eq "hex price"                 "$($N from-pod 0x82ff658cf0b3f0000)"     "151.03"
eq "hex margin"                "$($N from-pod 0x10c487e0e36b000)"       "0.075515"
eq "upper-case hex"            "$($N from-pod 0X56BC75E2D63100000)"     "100"
eq "decimal string"            "$($N from-pod 150930000000000000000)"   "150.93"
eq "below one"                 "$($N from-pod 75630000000000000)"       "0.07563"
eq "negative decimal"          "$($N from-pod -2648957182430000)"       "-0.00264895718243"
eq "negative hex"              "$($N from-pod -0x6f05b59d3b200000)"     "-8"
eq "smallest unit"             "$($N from-pod 1)"                       "0.000000000000000001"
eq "zero decimal"              "$($N from-pod 0)"                       "0"
eq "zero hex (no liquidation price is 0x0, which means none)" "$($N from-pod 0x0)" "0"
eq "minus zero"                "$($N from-pod -0)"                      "0"
eq "leading zeros"             "$($N from-pod 000100000000000000000000)" "100"
eq "exact past doubles"        "$($N from-pod 159369070615689195693819566)" "159369070.615689195693819566"
eq "past 64-bit, hex"          "$($N from-pod 0xffffffffffffffffffff)"  "1208925.819614629174706175"
eq "2^64 exactly"              "$($N from-pod 18446744073709551616)"    "18.446744073709551616"
eq "2^64 - 1 as hex"           "$($N from-pod 0xffffffffffffffff)"      "18.446744073709551615"
eq "2^53 + 1 (a double rounds it)" "$($N from-pod 9007199254740993 --decimals 0)" "9007199254740993"
eq "uint256 max"               "$($N from-pod 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff)" \
                               "115792089237316195423570985008687907853269984665640564039457.584007913129639935"
eq "open interest (staging)"   "$($N from-pod 6608727564314954766887280)" "6608727.56431495476688728"
eq "several values"            "$($N from-pod 0x0 1000000000000000000 | tr '\n' ' ')" "0 1 "
eq "--decimals 6"              "$($N from-pod 1500000 --decimals 6)"     "1.5"
eq "--decimals 0"              "$($N from-pod 0x1f916 --decimals 0)"     "129302"
refused "from-pod: text"       $N from-pod abc
refused "from-pod: a decimal point" $N from-pod 1.5
refused "from-pod: bad hex"    $N from-pod 0xzz
refused "from-pod: empty hex"  $N from-pod 0x

# to-pod: a plain decimal as pod's 10^18 integer
eq "price"                     "$($N to-pod 151.034)"                   "151034000000000000000"
eq "whole"                     "$($N to-pod 5)"                         "5000000000000000000"
eq "small size"                "$($N to-pod 0.000001)"                  "1000000000000"
eq "zero"                      "$($N to-pod 0)"                         "0"
eq "minus zero"                "$($N to-pod -0.0)"                      "0"
eq "negative size (a sell)"    "$($N to-pod -0.01)"                     "-10000000000000000"
eq "18 decimals"               "$($N to-pod 0.000000000000000001)"      "1"
eq "past 64-bit"               "$($N to-pod 18446744073709.551616)"     "18446744073709551616000000000000"
eq "past doubles"              "$($N to-pod 159369070.615689195693819566)" "159369070615689195693819566"
eq "hex output"                "$($N to-pod 100 --hex)"                 "0x56bc75e2d63100000"
eq "hex output, past 64-bit"   "$($N to-pod 1208925.819614629174706175 --hex)" "0xffffffffffffffffffff"
refused "to-pod: 19 decimals"  $N to-pod 0.0000000000000000001
refused "to-pod: exponent"     $N to-pod 1e5
refused "to-pod: dollar sign"  $N to-pod '$10'
refused "to-pod: comma"        $N to-pod 1,000
refused "to-pod: hex in"       $N to-pod 0x10
refused "to-pod: negative hex out" $N to-pod -1 --hex

# round trips: to-pod then from-pod gives the number back, and from-pod then to-pod the integer
for v in 151.03 0.000000000000000001 -2.5 0 123456789012345678901234567.123456789012345678 3570.12; do
  eq "round trip $v"           "$($N from-pod "$($N to-pod "$v")")"   "$v"
done
for v in 150930000000000000000 0x82ff658cf0b3f0000 115792089237316195423570985008687907853269984665640564039457584007913129639935 -1; do
  want=$($N int "$v")
  eq "round trip integer $v"   "$($N to-pod "$($N from-pod "$v")")"   "$want"
done

# int: unscaled integers (nonces, the nonce window bitmap, chain id)
eq "chain id"                  "$($N int 0x1f916)"                      "129302"
eq "nonce"                     "$($N int 0x32)"                         "50"
eq "128-bit bitmap"            "$($N int 0xffffffffffffffffffffffffffffffff)" "340282366920938463463374607431768211455"
eq "decimal stays"             "$($N int 007)"                          "7"
refused "int: text"            $N int seven

# time: microseconds as UTC
eq "on the second"             "$($N time 1795710282000000)"            "2026-11-26T16:24:42Z"
eq "half a second (a round)"   "$($N time 1795710282500000)"            "2026-11-26T16:24:42.500Z"
eq "microseconds kept"         "$($N time 1795710282000001)"            "2026-11-26T16:24:42.000001Z"
eq "pod's never (2^64 - 1)"    "$($N time 18446744073709551615)"        "never"
eq "hex microseconds"          "$($N time 0x66130618207a0)"             "2026-11-26T16:24:42.500Z"
eq "zero"                      "$($N time 0)"                           "1970-01-01T00:00:00Z"
refused "time: seconds by mistake"      $N time 1795710282
refused "time: milliseconds by mistake" $N time 1795710282500
refused "time: negative"       $N time -5
refused "time: too large"      $N time 99999999999999999999

# us: a UTC time as microseconds
eq "a date"                    "$($N us 2026-11-01)"                    "1793491200000000"
eq "a time"                    "$($N us 2026-11-01T12:00:00Z)"          "1793534400000000"
eq "with milliseconds"         "$($N us 2026-11-26T16:24:42.500Z)"      "1795710282500000"
eq "without seconds"           "$($N us 2026-11-01T12:00)"              "1793534400000000"
now=$(( $(date +%s) * 1000000 )); got=$($N us now)
eq "now (within 2 s)"          "$(( got - now < 2000000 && now - got < 2000000 ))" "1"
eq "time and us agree"         "$($N us "$($N time 1795710282500000)")" "1795710282500000"
refused "us: not a time"       $N us yesterday
refused "us: not a date"       $N us 2026-13-45

# help and misuse
eq "help"                      "$($N --help | head -1 | cut -c1-29)"    "Convert pod's numbers exactly"
refused "unknown command"      $N double 5
refused "no value"             $N from-pod

echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
