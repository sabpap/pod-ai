#!/usr/bin/env bash
set -euo pipefail

# Pod trading script
# Usage: ./trade.sh <market_id> <side> <size_usd> [price_override]
# side: "long" or "short"
# size_usd: dollar amount to trade (e.g. 5)

RPC="https://staging-rpc.podtestnet.dev"
ORDERBOOK="0x50d0000000000000000000000000000000000002"
KEYSTORE="pod-1-raw"
KEYSTORE_DIR="$HOME/.foundry/keystores"
ACCOUNT="0xaD60A063D766742A1b0bEed69e5425dBDf403834"

MARKET_ID="$1"       # e.g. 0007 for NVDA/USD perp
SIDE="$2"            # long or short
SIZE_USD="$3"        # dollar amount
PRICE_OVERRIDE="${4:-}"

# Get keystore password
KS_PASS=$(security find-generic-password -s foundry-keystore -a "$KEYSTORE" -w 2>/dev/null)

# Pad market ID to 32 bytes (input is hex, e.g. "7" or "0c")
ORDERBOOK_ID="0x$(printf '%064s' "$MARKET_ID" | tr ' ' '0')"

# Get current mark price from stats
MARK_PRICE=$(curl -s "${RPC}/v1/clob/markets/stats" | python3 -c "
import json, sys
data = json.load(sys.stdin)
target = '$ORDERBOOK_ID'
for m in data['markets']:
    if m['orderbook_id'] == target:
        mp = float(m.get('mark_price', '0')) / 1e18
        lp = float(m.get('last_clearing_price', '0')) / 1e18
        price = mp if mp > 0 else lp
        print(f'{price:.2f}')
        sys.exit(0)
print('0')
")

if [ "$MARK_PRICE" = "0" ]; then
    echo "ERROR: Could not get price for market $MARKET_ID"
    exit 1
fi

echo "Market price: \$${MARK_PRICE}"

# Calculate size in base units (1e18 scale for perps with lot_size=1e12)
# size_base = size_usd / price, then scale to 1e18
# But perp lot_size is 1e12, so we round to nearest lot
SIZE_BASE=$(python3 -c "
import math
price = $MARK_PRICE
size_usd = $SIZE_USD
size_base = size_usd / price  # in whole units
size_wei = int(size_base * 1e18)
# Round to nearest lot (1e12)
lot = 1000000000000
size_wei = (size_wei // lot) * lot
if size_wei < lot:
    size_wei = lot
print(size_wei)
")

# For short, negate the size
if [ "$SIDE" = "short" ]; then
    # cast needs negative as a signed int256
    # We pass the negative value directly
    SIZE_SIGNED="-${SIZE_BASE}"
else
    SIZE_SIGNED="${SIZE_BASE}"
fi

# Set price: for market orders use a generous limit
# For longs: price * 1.02 (2% above), for shorts: price * 0.98 (2% below)
if [ -n "$PRICE_OVERRIDE" ]; then
    LIMIT_PRICE="$PRICE_OVERRIDE"
else
    LIMIT_PRICE=$(python3 -c "
price = $MARK_PRICE
if '$SIDE' == 'long':
    lp = price * 1.02
else:
    lp = price * 0.98
# Scale to 1e18
lp_wei = int(lp * 1e18)
# Round to tick (1e16)
tick = 10000000000000000
lp_wei = (lp_wei // tick) * tick
print(lp_wei)
")
fi

# Calculate deadline: round up current time to next auction boundary (500ms = 500000us)
# Add 10 seconds of lag
DEADLINE=$(python3 -c "
import time
now_us = int(time.time() * 1_000_000)
lag_us = 10_000_000  # 10 seconds
target = now_us + lag_us
interval = 500_000
deadline = ((target + interval - 1) // interval) * interval
print(deadline)
")

# TTL: 60 seconds in microseconds
TTL=60000000

# Order type: 0 = Limit (we use limit with generous price to act like market)
ORDER_TYPE=0

# Flags: 0 (no special flags)
FLAGS=0

echo "Submitting $SIDE order: market=$MARKET_ID size=${SIZE_BASE} wei ($SIZE_USD USD) price_limit=${LIMIT_PRICE} deadline=${DEADLINE}"

# Send the transaction using cast
TX_HASH=$(cast send \
    --keystore "${KEYSTORE_DIR}/${KEYSTORE}" \
    --password "$KS_PASS" \
    --rpc-url "$RPC" \
    --chain 129302 \
    "$ORDERBOOK" \
    "submitOrder(bytes32,int256,uint256,uint8,uint128,uint128,uint8)" \
    "$ORDERBOOK_ID" \
    "$SIZE_SIGNED" \
    "$LIMIT_PRICE" \
    "$ORDER_TYPE" \
    "$DEADLINE" \
    "$TTL" \
    "$FLAGS" \
    2>&1)

echo "Result: $TX_HASH"
