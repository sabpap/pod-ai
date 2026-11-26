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
eq "jq: time between rounds"   "$(J '"1795710282500000" | us_time_ms')"  "2026-11-26T16:24:42.500Z"
eq "jq: round on the second"   "$(J '1795710282000000 | us_time_ms')"    "2026-11-26T16:24:42Z"
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

# to_wei: a user's decimal as pod's 10^18 integer
eq "wei: price"                "$(to_wei 151.034)"     "151034000000000000000"
eq "wei: whole"                "$(to_wei 5)"           "5000000000000000000"
eq "wei: small size"           "$(to_wei 0.000001)"    "1000000000000"
eq "wei: zero"                 "$(to_wei 0)"           "0"
eq "wei: 18 decimals"          "$(to_wei 0.000000000000000001)" "1"
eq "wei: 19 decimals refused"  "$(to_wei 0.0000000000000000001 || echo refused)" "refused"
eq "wei: negative refused"     "$(to_wei -1 || echo refused)"   "refused"
eq "wei: text refused"         "$(to_wei 1e5 || echo refused)"  "refused"

# duration_s: resting times
eq "duration 10m"              "$(duration_s 10m)"     "600"
eq "duration 1d"               "$(duration_s 1d)"      "86400"
eq "duration bad"              "$(duration_s 1w || echo refused)" "refused"

# rounding as trade.sh does it: buy price down, sell price up, size down (tick 0.01, lot 0.000001)
TICK=10000000000000000; LOT=1000000000000
eq "buy price rounds down"     "$(bc_int "151034000000000000000 / $TICK * $TICK")"              "151030000000000000000"
eq "sell price rounds up"      "$(bc_int "(151034000000000000000 + $TICK - 1) / $TICK * $TICK")" "151040000000000000000"
eq "price on a step stays"     "$(bc_int "(151030000000000000000 + $TICK - 1) / $TICK * $TICK")" "151030000000000000000"
eq "size rounds down"          "$(bc_int "12345678900000000 / $LOT * $LOT")"                    "12345000000000000"
eq "2% band for a buy"         "$(bc_int "(150890000000000000000 * (10000 + 200) / 10000) / $TICK * $TICK")" "153900000000000000000"

# short_addr
eq "short address"             "$(short_addr 0x035A9E2f3ED8bAAD656E66BF3f0071da40DcDa70)" "0x035A…Da70"

# next_nonce: a real 0 passes, a failed or empty lookup stops instead of becoming 0
ADDR=0x035A9E2f3ED8bAAD656E66BF3f0071da40DcDa70
nonce_of() { ( next_nonce test "retry"; echo "$NEXT_NONCE" ) | jq -r 'if type == "object" then "refused: " + .error else . end' 2>/dev/null; }
rpc_result() { echo '"0x0"'; };  eq "nonce: fresh account is 0"  "$(nonce_of)" "0"
rpc_result() { echo '"0x1f"'; }; eq "nonce: hex"                 "$(nonce_of)" "31"
rpc_result() { echo 'null'; };   eq "nonce: null refused"        "$(nonce_of | cut -c1-8)" "refused:"
rpc_result() { return 0; };      eq "nonce: empty refused"       "$(nonce_of | cut -c1-8)" "refused:"
rpc_result() { return 2; };      eq "nonce: pod error refused"   "$(nonce_of | cut -c1-8)" "refused:"
unset -f rpc_result; source "$(cd "$(dirname "$0")/../scripts" && pwd)/lib.sh"; set +e
POD_RPC=http://127.0.0.1:9;      eq "nonce: no answer refused"   "$(nonce_of | cut -c1-8)" "refused:"

echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
