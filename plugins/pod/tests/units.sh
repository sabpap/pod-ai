#!/usr/bin/env bash
# Offline tests of the number helpers in scripts/lib.sh. No network, no wallet.
# Usage: plugins/pod/tests/units.sh

set -uo pipefail
source "$(cd "$(dirname "$0")/../scripts" && pwd)/lib.sh"
set +e   # lib.sh turns on -e; a failed comparison here must not stop the run

pass=0; failed=0
eq() {   # eq NAME GOT WANT
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"
  else failed=$((failed+1)); echo "FAIL $1: got '$2', want '$3'"; fi
}

# to_dec: pod sends 10^18-scaled numbers as hex or as decimal strings
eq "hex to decimal"            "$(to_dec 0x56bc75e2d63100000)"      "100000000000000000000"
eq "upper-case hex"            "$(to_dec 0X56BC75E2D63100000)"      "100000000000000000000"
eq "decimal passes through"    "$(to_dec 150930000000000000000)"    "150930000000000000000"
eq "zero hex"                  "$(to_dec 0x0)"                      "0"
eq "past 64-bit integers"      "$(to_dec 0xffffffffffffffffffff)"   "1208925819614629174706175"

# human: a scaled integer as a plain decimal
eq "whole dollars"             "$(human 100000000000000000000)"     "100"
eq "cents"                     "$(human 150930000000000000000)"     "150.93"
eq "below one"                 "$(human 75630000000000000)"         "0.07563"
eq "zero"                      "$(human 0)"                         "0"
eq "negative"                  "$(human -500000000000000000)"       "-0.5"
eq "from hex"                  "$(human 0x56bc75e2d63100000)"       "100"
eq "smallest unit"             "$(human 1)"                         "0.000000000000000001"

# bc_int: integer maths past 64 bits, as the test order's price and size use it
eq "half price on the tick"    "$(bc_int "(151260000000000000000 / 2) / 10000000000000000 * 10000000000000000")" "75630000000000000000"
eq "size up to the lot"        "$(bc_int "(10^15 + 1000000000000 - 1) / 1000000000000 * 1000000000000")" "1000000000000000"
eq "comparison true"           "$(bc_int "100000000000000000000 > 0")"   "1"
eq "comparison false"          "$(bc_int "0 > 0")"                       "0"

# send_failure_kind: which refusals last (status drops to "problem") and which pass
eq "region block lasts"        "$(send_failure_kind -32025 'not available in your region')" "lasting"
eq "blacklist lasts"           "$(send_failure_kind -32000 'Transaction is blacklisted')"   "lasting"
eq "locked account lasts"      "$(send_failure_kind -32000 'account is locked')"            "lasting"
eq "nonce clash passes"        "$(send_failure_kind -32000 'nonce too low')"                "passing"
eq "pending tx passes"         "$(send_failure_kind -32000 'Account has pending transaction')" "passing"

# money: the summary line's dollar amounts
eq "money keeps small moves"   "$(money 99.99666537511088)"   "99.9967"
eq "money whole dollars"       "$(money 100.000000)"          "100"
eq "money cents"               "$(money 150.93)"              "150.93"
eq "money zero"                "$(money 0)"                   "0"
eq "money negative"            "$(money -0.00264895718243)"   "-0.0026"

# pod.jq: exact conversion of pod's numbers, as the account views use it
J() { jq -rn -L "$(cd "$(dirname "$0")/../scripts" && pwd)" "include \"pod\"; $1"; }
eq "jq: hex price"             "$(J '"0x82ff658cf0b3f0000" | amount')"   "151.03"
eq "jq: hex margin"            "$(J '"0x10c487e0e36b000" | amount')"     "0.075515"
eq "jq: negative decimal"      "$(J '"-2648957182430000" | amount')"     "-0.00264895718243"
eq "jq: exact past doubles"    "$(J '"159369070615689195693819566" | amount')" "159369070.615689195693819566"
eq "jq: no liquidation price"  "$(J '"0x0" | price_or_null')"            "null"
eq "jq: zero amount"           "$(J '"0x0" | amount')"                   "0"
eq "jq: microseconds to time"  "$(J '"1795703805500000" | us_time')"     "2026-11-26T14:36:45Z"
eq "jq: pod's never"           "$(J '18446744073709551615 | us_time')"   "null"
eq "jq: computed, rounded"     "$(J '99.99666537511088 | fixed(4)')"     "99.9967"
eq "jq: computed, negative 0"  "$(J '-0.0026 | fixed(2)')"               "0"
eq "jq: computed, millions"    "$(J '159369070.615689195 | fixed(8)')"   "159369070.615689"
eq "jq: computed, billions"    "$(J '12345678901.23 | fixed(8)')"        "12345678901.23"
eq "jq: computed, trillions"   "$(J '-1234567890123456.7 | fixed(8)')"   "-1234567890123457"
eq "jq: computed, tiny"        "$(J '0.000000123456 | fixed(8)')"        "0.00000012"

# since_us: the --since values
now=$(( $(date +%s) * 1000000 ))
eq "since 7d"                  "$(( (now - $(since_us 7d)) / 86400000000 ))"   "7"
eq "since 30m"                 "$(( (now - $(since_us 30m)) / 60000000 ))"     "30"
eq "since a date"              "$(since_us 2026-11-01)"                         "1793491200000000"
eq "since a time"              "$(since_us 2026-11-01T12:00:00Z)"               "1793534400000000"
eq "since nonsense refused"    "$(since_us 7x || echo refused)"                 "refused"
eq "since letters refused"     "$(since_us abcd || echo refused)"               "refused"

# short_addr
eq "short address"             "$(short_addr 0x035A9E2f3ED8bAAD656E66BF3f0071da40DcDa70)" "0x035A…Da70"

echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
