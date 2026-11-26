# Trading: build, send and confirm an order

Every trading action is one signed transaction to pod's order book contract `0x50d0000000000000000000000000000000000002`. You build the call from this recipe; `pod-send.sh` only signs and sends it. Numbers and times follow [basics.md](basics.md).

## Contents

- [The recipe at a glance](#the-recipe-at-a-glance)
- [0. A wallet, and the user's yes](#0-a-wallet-and-the-users-yes)
- [1. Read the market's rules](#1-read-the-markets-rules)
- [2. Work out price and size](#2-work-out-price-and-size)
- [3. Deadline and resting time](#3-deadline-and-resting-time)
- [4. Encode the call](#4-encode-the-call)
- [5. Show it and ask](#5-show-it-and-ask)
- [6. Send](#6-send)
- [7. Read the real outcome](#7-read-the-real-outcome)
- [Recipes](#recipes)
- [Why pod refuses](#why-pod-refuses)

## The recipe at a glance

1. Check the wallet (`pod-send.sh --check`).
2. Read the market's rules from `GET /v1/clob/markets`: `id`, `status`, price step, size step, minimum value, fees, margin rate.
3. Work out the price and the size in units, convert them to pod's integers, and round them to the steps on the side that never trades worse.
4. Set the deadline on the 500 ms grid, in microseconds, and the resting time as an absolute end time.
5. Encode the call with its exact signature.
6. Show the user what will be sent, and ask.
7. Send with `pod-send.sh`. `"accepted": true` means pod took the transaction, not that anything traded.
8. After the deadline's round, read the order's real status.

## 0. A wallet, and the user's yes

```bash
pod-send.sh --check
```

It says which wallet will sign (`wallet.address`), that pod staging answers, and whether writes are open. On `"ok": false` with `step: "wallet"`, tell the user the `fix` and stop: **never ask for a private key or password in the chat.** The user provides a wallet by exporting `POD_PRIVATE_KEY` in the shell that starts the agent, or by naming a Foundry keystore (`--keystore NAME`, or `POD_KEYSTORE`) whose password they stored in the macOS Keychain themselves.

The account pays a tiny fee in cash for each transaction, so check `cash` in `GET /v1/clob/balances/{address}` before trading.

**Before sending anything that trades, show the user what will be sent and ask.** Nothing enforces this: it is up to you.

## 1. Read the market's rules

```bash
V=https://staging-rpc.podtestnet.dev/v1
curl -s "$V/clob/markets" | jq '.[] | select(.base_token_symbol == "NVDA" and .market_type == "perp")'
```

Keep: `id` (the market id), `status` (must be `active`), `market_type`, `tick_precision` (price step), `lot_size` (size step), `min_notional`, `maker_fee`, `taker_fee`, `initial_margin`, `auction_interval_us`, and `disable_at_us` if present (an order whose deadline is past a scheduled halt is refused). See [markets.md](markets.md#finding-a-market-by-name) to match a loose name.

## 2. Work out price and size

### A size is in units of the asset, not dollars

`0.5` on NVDA means half a share's worth of exposure, about $75; `0.5` on gold means about $1,800. "Buy a little of each" with the same size in every market puts very different amounts of money into each: a real test bought 0.01 of seven markets and gold became 60% of the exposure. When the user names money ("$10 of NVDA", "the same amount in each"), size by money:

```
size = dollars × 10^18 ÷ price, rounded DOWN to the size step
```

Use the limit price for a limit order and the current price (the mark on perps, the last price on spot) for a market order. Tell the user the size it came to.

### Convert and round

Convert decimals to pod's integers with `pod-number.sh to-pod`, then round with `bc`, which is exact on integers (`scale` 0 divides to whole numbers):

```bash
TICK=10000000000000000          # tick_precision: 0.01
LOT=1000000000000               # lot_size: 0.000001
P=$(pod-number.sh to-pod 151.034)                        # 151034000000000000000
BUY_PRICE=$(echo "$P / $TICK * $TICK" | bc)              # 151030000000000000000  (buy: round DOWN)
SELL_PRICE=$(echo "($P + $TICK - 1) / $TICK * $TICK" | bc)  # 151040000000000000000  (sell: round UP)
S=$(pod-number.sh to-pod 0.0123456)
SIZE=$(echo "$S / $LOT * $LOT" | bc)                     # 12345000000000000  (size: round DOWN)
```

**Round on the side that never trades worse than asked**: a buy price down, a sell price up, a size down. Tell the user about each change ("151.034 → 151.03"). A size that rounds to 0 is smaller than the market's step: refuse it. Do not send a price or size off its step: pod refuses it (for a change to a resting order its reasons are `price_off_tick` and `size_off_lot`).

### The worst price of a market order

A market order still carries a price: the worst price it may fill at. Take the current price (mark on perps, last on spot) and a band, 2% unless the user says otherwise:

```bash
MARK=150178932253596000000      # mark_price from /v1/clob/markets/stats
BUY_WORST=$(echo "$MARK * 10200 / 10000 / $TICK * $TICK" | bc)              # +2%, rounded down
SELL_WORST=$(echo "($MARK * 9800 / 10000 + $TICK - 1) / $TICK * $TICK" | bc)  # −2%, rounded up
```

A market order fills at the round's one clearing price, which is usually far better than the worst price. Show the user the value at the current price, and the worst case beside it.

### Checks before going on

| Check | How |
|---|---|
| The side | Size **positive to buy** (go long), **negative to sell** (go short, or reduce a long). Selling a perp you do not hold opens a short |
| Order value | `SIZE × PRICE / 10^18` (bc). At least `min_notional` |
| Fee | value × `taker_fee` (or `maker_fee` for a maker-only order). `pod-number.sh to-pod 0.000450` gives the rate scaled by 10^18; then `value × rate / 10^18` |
| Margin needed (perps) | value × `initial_margin` / 10^18. Free margin = `account_value` − sum of the positions' `margin` ([account.md](account.md#numbers-worth-working-out)). Not enough free margin: pod removes the order as `margin_canceled` |
| Spot | A buy needs the cash; a sell needs the tokens (`free_balance` in `/clob/balances`) |

## 3. Deadline and resting time

**The deadline** is the last round the order may enter. It is in **microseconds** and must be a **multiple of the market's `auction_interval_us`** (500,000 on staging), or pod refuses it: `Deadline is not aligned to auction interval`. Give it a few seconds of headroom so the transaction reaches the validators in time; 5 seconds is what was tested end to end on staging. Pod's docs allow up to 10 minutes and suggest more headroom on a busy network; the order may then enter an earlier round than its deadline, but never a later one.

```bash
NOW=$(pod-number.sh us now)
DEADLINE=$(( (NOW + 5000000 + 499999) / 500000 * 500000 ))   # next 500 ms boundary at least 5 s ahead
```

**The `ttl` is an absolute end time, not a duration**, also in microseconds. A duration such as `86400000000` would be read as a date in 1970, and the order would end at once.

```bash
TTL=$(( DEADLINE + 86400 * 1000000 ))   # rests one day after its deadline
```

Use the same deadline for every call in one batch. Compute the deadline just before sending: a deadline that has passed is refused.

## 4. Encode the call

Encode against the **exact** signature below. The selector changes with any difference; `submitOrder` has an older overload with two `bool`s that cannot request maker-only.

| Action | Signature | Arguments, in order |
|---|---|---|
| Place an order | `submitOrder(bytes32,int256,uint256,uint8,uint128,uint128,uint8)` | market id, **signed** size, price, order type, deadline, ttl, flags |
| Change an order | `update(bytes32,bytes32,uint256,uint256,address,uint128)` | market id, order id, new **total** size (unsigned), new price, token, deadline |
| Cancel an order | `cancel(bytes32,bytes32,uint128)` | market id, order id, deadline |
| Arm a trigger | `submitTrigger(bytes32,int256,uint256,uint256,uint8,uint8,uint128,uint128,bool,bool)` | market id, signed size, limit price, trigger price, trigger type, grouping, deadline, ttl, reduce-only, immediate-or-cancel |
| Change a trigger | `updateTrigger(bytes32,bytes32,int256,uint256,uint256,uint128)` | market id, trigger id, new signed size, new limit price, new trigger price, deadline |
| Cancel a trigger | `cancelTrigger(bytes32,bytes32,uint128)` | market id, trigger id, deadline |
| Several at once | `submitBatch(bytes[])` | 1 to 64 full calls, each with its selector (`cast calldata …`) |

**Order type** (`uint8`): `0` limit, `1` market.

**Flags** (`uint8`, add them up; other bits must be 0):

| Value | Flag | Meaning |
|---|---|---|
| `1` | reduce-only | May only shrink an existing position. Perps only |
| `2` | immediate-or-cancel | Whatever does not fill in its round is cancelled. **Required on a market order** |
| `4` | maker-only (post-only) | Refused (`post_only_refused`) if it would cross the book left by the previous round |

Pod refuses `2 + 4` (immediate-or-cancel with maker-only) and maker-only on a market order. A plain limit order is `0`; a market order is `2` (or `3` with reduce-only).

**Trigger type**: `0` take-profit, `1` stop-loss. **Grouping**: `0` none, `1` asset (the trigger, and any order it placed, is removed when the position closes).

**Token for `update`**: the USD token `0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee` (checked on perps). For spot, check pod's [orderbook docs](https://github.com/podnetwork/pod-sdk/blob/main/doc/api-reference/applications-precompiles/orderbook.md) first.

Arguments go to `cast` as plain decimal integers (`10000000000000000`, `-10000000000000000`), `0x` hex for ids and addresses, `true`/`false` for bools. `pod-send.sh SIGNATURE ARGS…` encodes them; `cast calldata SIGNATURE ARGS…` shows the encoding without signing.

**The new order's id** is `keccak256(abi.encode(signer, nonce, sequence))`, with sequence 0 for a single call and the position (0, 1, 2…) inside a batch. `pod-send.sh` prints it as `order_id` for `submitOrder` and `submitTrigger`. For a batch, work it out from the `nonce` it prints:

```bash
cast keccak "$(cast abi-encode 'f(address,uint64,uint32)' 0xSIGNER NONCE SEQUENCE)"
```

## 5. Show it and ask

Before sending anything that trades, show the user what will be sent and ask. A useful preview, in plain words: market, buy or sell, size in units, price (after rounding, saying what changed) or the worst price for a market order, value in USD at the current price, fee, margin needed and free margin after (perps), flags, and how long it rests. Then wait for a clear yes.

To show exactly what would be signed, without sending:

```bash
pod-send.sh --dry-run 'submitOrder(bytes32,int256,uint256,uint8,uint128,uint128,uint8)' \
  0x0000000000000000000000000000000000000000000000000000000000000007 10000000000000000 \
  151030000000000000000 0 "$DEADLINE" "$TTL" 0
```

## 6. Send

The same command without `--dry-run`:

```bash
pod-send.sh 'submitOrder(bytes32,int256,uint256,uint8,uint128,uint128,uint8)' \
  0x0000000000000000000000000000000000000000000000000000000000000007 10000000000000000 \
  151030000000000000000 0 "$DEADLINE" "$TTL" 0
```

It checks the chain is pod staging, reads the next nonce (`eth_getTransactionCount` with `pending`), signs with `cast`, checks the signed transaction matches the request, sends it with `eth_sendRawTransaction`, and waits up to 10 seconds for `pod_getTxStatus`. Its answer:

| Field | Meaning |
|---|---|
| `ok`, `sent` | Whether it was sent and not refused |
| `tx` | The transaction hash |
| `nonce`, `from` | The nonce used and the signer |
| `order_id` | The id of the order or trigger it creates (single `submitOrder` or `submitTrigger`) |
| `tx_status` | Pod's `pod_getTxStatus` answer, unchanged |
| `accepted` | `true`: finalized and executed. `false`: executed and failed. `null`: not final yet |
| `pod_error`, `reason`, `fix` | When pod refused it ([basics.md](basics.md#errors)) |

Tell the user at once: "Sent and accepted; waiting for the round." **Accepted is not filled.**

**Nonces.** Send one transaction at a time and wait for its answer before the next. On error `996` (a past or future nonce, or a pending transaction), check `pod_getTxStatus` of the earlier attempt, then send again: `pod-send.sh` reads a fresh nonce each time. When pod did not answer the send at all, the transaction may still have arrived: check `pod_getTxStatus` of the printed `tx` before sending again, or the order could be placed twice. To send many transactions without waiting, pod lets any free nonce in the window `[watermark, watermark + 128)` be used (`GET /v1/accounts/{address}/nonce-slots`); pass each with `--nonce N`.

## 7. Read the real outcome

The order trades, rests or is refused in a round no later than its deadline. Once that round has passed, read the order, asking pod to wait until it has indexed that round:

```bash
curl -s "$V/clob/orders/$ADDRESS?orderbook=$MARKET_ID&limit=50&timestamp=$DEADLINE" \
  | jq --arg id "$ORDER_ID" '.orders[] | select(.order_id == $id)'
```

| `status` | Tell the user |
|---|---|
| `pending` | Not in a round yet: ask again shortly |
| `active`, nothing filled | Resting in the book at its price, until `end` |
| `active`, `filled_base_amount` above 0 | Partly filled at `effective_price`; the rest rests |
| `filled` | Filled at an average `effective_price`, fee `fee` |
| `expired` | Nothing (or only part) was available at its price before it ended. For a market order: the unfilled rest was cancelled |
| `canceled` | Cancelled |
| `margin_canceled` | Refused: not enough margin |
| `post_only_refused` | Refused: maker-only, and it would have traded at once |
| `self_trade_canceled` | Removed: it would have traded with your own order |
| `invalid` | Refused: `invalid_reason` |

Other actions:

| Action | Where the outcome shows |
|---|---|
| Cancel | The order's `status` becomes `canceled`. If it filled first, it stays `filled`. A refused cancel is a `cancel_reject` entry with `why` in `/clob/activity/{a}?activity_types=cancel_reject` |
| Change (`update`) | The order's `price` and `initial_size` change, and a `modify` entry appears in activity. A refused change is a `modify_reject` with `why`. Changing a maker-only order onto a crossing price cancels it |
| Trigger armed, changed or cancelled | `GET /clob/triggers/{a}`: it appears, changes, or is gone |
| Position | `GET /clob/positions/{a}?timestamp=$DEADLINE` |

To be told the moment the outcome arrives instead of asking again, follow `pod_orders_v2` or `pod_receipts` ([live.md](live.md)).

## Recipes

All use `TICK`, `LOT`, `DEADLINE` and `TTL` from above, `BOOK` for the market id, and `OB=0x50d0000000000000000000000000000000000002`.

**Buy 0.5 NVDA at $150, limit, rests 1 day**

```bash
pod-send.sh 'submitOrder(bytes32,int256,uint256,uint8,uint128,uint128,uint8)' \
  "$BOOK" 500000000000000000 150000000000000000000 0 "$DEADLINE" "$TTL" 0
```

**Sell 0.5 at market, no worse than 2% below the mark** (`SELL_WORST` from step 2; type 1, flags 2)

```bash
pod-send.sh 'submitOrder(bytes32,int256,uint256,uint8,uint128,uint128,uint8)' \
  "$BOOK" -500000000000000000 "$SELL_WORST" 1 "$DEADLINE" "$TTL" 2
```

**Maker-only limit buy**: flags `4`, order type 0. If it would cross the book, pod refuses it instead of trading.

**Close a perp position**: read `size` from `/clob/positions/{a}`. Send the opposite sign of the same size, reduce-only, at market: size `−size`, worst price from the band on the closing side, type `1`, flags `3` (reduce-only + immediate-or-cancel). For half, take half the size rounded down to the lot.

**Change an order's price or size**: read the order from `/clob/orders/{a}` (its `orderbook_id`, `order_id`, `side`, current `price` and `initial_size`). Round the new price on the order's side. The new size is the order's new **total**, unsigned.

```bash
pod-send.sh 'update(bytes32,bytes32,uint256,uint256,address,uint128)' \
  "$BOOK" "$ORDER_ID" 500000000000000000 149000000000000000000 0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee "$DEADLINE"
```

**Cancel an order**

```bash
pod-send.sh 'cancel(bytes32,bytes32,uint128)' "$BOOK" "$ORDER_ID" "$DEADLINE"
```

**Cancel all open orders**: list `status=active` and `status=pending` (all pages), then send `submitBatch` with one `cancel` per order, 64 per transaction, all with the same deadline. Triggers are separate: cancel them with `cancelTrigger`.

```bash
C1=$(cast calldata 'cancel(bytes32,bytes32,uint128)' "$BOOK" "$ID1" "$DEADLINE")
C2=$(cast calldata 'cancel(bytes32,bytes32,uint128)' "$BOOK" "$ID2" "$DEADLINE")
pod-send.sh 'submitBatch(bytes[])' "[$C1,$C2]"
```

A batch is atomic: it lands in one round as a whole. Nested batches are refused.

**Stop-loss on a whole long position, at market when it fires** (checked on staging): size `0` with grouping `1` (asset) sizes it from the whole position when it fires, long or short. The trigger price must be **below** the mark for a long's stop-loss (above for a short's), or it fires at once. Round it on the closing side. The limit price is the worst price when it fires: for a long (closing side sell), the trigger price minus 2%, rounded up.

```bash
pod-send.sh 'submitTrigger(bytes32,int256,uint256,uint256,uint8,uint8,uint128,uint128,bool,bool)' \
  "$BOOK" 0 "$LIMIT" "$TRIGGER" 1 1 "$DEADLINE" $(( DEADLINE + 30 * 86400 * 1000000 )) true true
```

**Take-profit**: the same with trigger type `0`, and the trigger price on the winning side (above the mark for a long). With a limit price instead of at market, set the last argument (immediate-or-cancel) to `false`.

How a trigger fires (the side is the sign of the order it places, the closing side):

| Order it places | Take-profit fires when | Stop-loss fires when |
|---|---|---|
| Sell (closes a long) | mark ≥ trigger | mark ≤ trigger |
| Buy (closes a short) | mark ≤ trigger | mark ≥ trigger |

**Change a trigger**: `updateTrigger` takes all three values; send the unchanged ones as they are in `/clob/triggers/{a}`. Grouping cannot change.

**Cancel a trigger**

```bash
pod-send.sh 'cancelTrigger(bytes32,bytes32,uint128)' "$BOOK" "$TRIGGER_ID" "$DEADLINE"
```

A stop-loss or take-profit is watched by pod itself: it needs no listener.

## Why pod refuses

| Seen | Cause | Fix |
|---|---|---|
| `Deadline is not aligned to auction interval` (code 3) | The deadline is not a multiple of 500,000 µs, or is in seconds or milliseconds | Recompute it as in step 3 |
| The order ends at once, `expired` | `ttl` given as a duration, not an absolute time | `ttl` = deadline + resting time |
| `market orders must be immediate-or-cancel` | A market order without flag 2 | Flags `2` (or `3`) |
| `post-only …` | Maker-only with immediate-or-cancel, or on a market order | Drop one of them |
| `post_only_refused` status | A maker-only order would have crossed | Lower a buy, raise a sell, or drop maker-only |
| `margin_canceled` status | Not enough free margin | A smaller size, or close something first |
| `invalid` with `invalid_reason` | Refused at execution, for the reason given | Fix what the reason names |
| `price_off_tick`, `size_off_lot` (a refused change) | The new price or size is not on the market's step | Round as in step 2 |
| `996` | Nonce clash or pending transaction | Check the earlier attempt, send again |
| `Insufficient balance` (-32000) | No cash for the fee | The account needs cash |
| `-32025` | Region blocked | Lasting: this wallet cannot trade from here |
| `market disables at …` | The market has a scheduled halt before the deadline | A shorter deadline, or another market |
