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

# short_addr
eq "short address"             "$(short_addr 0x035A9E2f3ED8bAAD656E66BF3f0071da40DcDa70)" "0x035A…Da70"

echo "$pass passed, $failed failed"
[ "$failed" -eq 0 ]
