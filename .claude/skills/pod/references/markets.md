# Markets: what is traded, at what price

Every route here is a public `GET` on `https://staging-rpc.podtestnet.dev/v1`; no wallet is needed. Numbers follow [basics.md](basics.md).

## Contents

- [Pick the route from the question](#pick-the-route-from-the-question)
- [The market list and its rules](#the-market-list-and-its-rules)
- [Finding a market by name](#finding-a-market-by-name)
- [Live numbers: stats](#live-numbers-stats)
- [Which price to quote](#which-price-to-quote)
- [The order book](#the-order-book)
- [What a size would cost now](#what-a-size-would-cost-now)
- [Price bars (candles)](#price-bars-candles)
- [Per-round history (solutions)](#per-round-history-solutions)
- [Network activity](#network-activity)

## Pick the route from the question

| The user asks | Route |
|---|---|
| "What can I trade?", "is there a Hynix market?" | `/clob/markets` (+ `/clob/markets/stats` for prices) |
| "What's NVDA's price?", "how is gold doing?", "top movers" | `/clob/markets/stats` |
| "NVDA order book", "what's the spread?", "what would 10 cost?" | `/clob/orderbook/{id}` |
| "Hourly bars", "price history" | `/clob/candles/{id}` |
| "Funding history", "mark against oracle over time" | `/clob/solutions?orderbook={id}` |
| "How busy is the network?", "show transaction 0x…" | `/transactions`, `/tx/{hash}`, `eth_blockNumber` |

Company information (descriptions, real exchange hours) is not in pod's API.

## The market list and its rules

`GET /clob/markets`: every market and its fixed rules, as one JSON array. About 60 on staging, perps and spot; most `active`, a few `disabled`.

| Field | Meaning |
|---|---|
| `id` | The market id (32 bytes) |
| `status` | `pending`, `active`, `disabled` (halted: every order is refused), `settled`. Trade only `active` |
| `name`, `base_token_symbol`, `base_token_name`, `market_type` | `NVDA/USD`, `NVDA`, `Nvidia Perpetual`, `perp` (or `spot`) |
| `tick_precision` | **Price step**, scaled by 10^18 (`10000000000000000` = 0.01). Every price must be a multiple |
| `lot_size` | **Size step**, scaled by 10^18 (`1000000000000` = 0.000001). Every size must be a multiple |
| `min_notional` | Smallest order value in USD, scaled by 10^18. `"0"` means no minimum (true for every staging market when checked) |
| `maker_fee`, `taker_fee` | Plain decimal fractions: `"0.000150"` is 0.015%, `"0.000450"` is 0.045% |
| `max_leverage` | Perps: an integer, e.g. 20 |
| `initial_margin` | Perps: margin rate scaled by 10^18 (`50000000000000000` = 5%). Margin needed = order value × this |
| `auction_interval_us` | Time between rounds: 500000 (half a second) on staging. Deadlines must be multiples of it |
| `funding_window_us` | The period a funding rate applies to: 28800000000 (8 hours) |
| `live_at_us`, `disable_at_us`, `settlement_price` | When a pending market opens, when a halt is scheduled, the price positions settle at after a halt. Missing when not set |

```bash
curl -s https://staging-rpc.podtestnet.dev/v1/clob/markets \
  | jq '.[] | select(.base_token_symbol == "NVDA" and .market_type == "perp")
        | {id, status, tick_precision, lot_size, min_notional, taker_fee, initial_margin, auction_interval_us}'
```

## Finding a market by name

Users say "nvidia", "NVDA", "gold", "hynix spot". Match, without case, on `base_token_symbol`, `base_token_name` and `name`, and on the symbol plus `x` for spot. When a name has both a perp and a spot market, take the **perp** unless the user says spot. When nothing matches exactly, search with `contains` and ask if several fit. Always use the `id` you found in later calls, never the name.

## Live numbers: stats

`GET /clob/markets/stats`: `{"solution_now": …, "markets": [ … ]}`, one entry per market, all prices and amounts as decimal strings scaled by 10^18. Fields are left out until pod has data.

| Field | Meaning |
|---|---|
| `orderbook_id` | The market |
| `last_clearing_price` | The price the latest round with a trade cleared at |
| `mark_price` | Perps. What positions are valued and liquidated at, smoothed against the oracle |
| `oracle_price` | Perps. The outside reference price (e.g. the real NVDA stock) |
| `internal` | `true`: every outside source is stale (for a stock, usually because its exchange is closed), so the oracle is derived from pod's own book. Say so when quoting |
| `price_change_24h` | **Basis points**: 228 is +2.28% |
| `high_24h`, `low_24h` | 24-hour range |
| `volume_24h` | USD traded in 24 hours |
| `open_interest` | Perps. USD value of open positions |
| `funding_rate` | Perps. Signed, per `funding_window_us`. Positive: longs pay shorts. Negative: shorts pay longs |

"Top movers": sort the active markets by `price_change_24h` (numbers, not strings), and by `volume_24h` for "most traded".

## Which price to quote

| Price | Use |
|---|---|
| **Mark** (`mark_price`) | **The headline price on perps.** Positions are valued and liquidated at it. A market order's worst price starts from it |
| **Last traded** (`last_clearing_price`) | **The headline price on spot**, which has no mark. Also the "last trade" on perps |
| **Oracle** (`oracle_price`) | The outside reference. Useful for "mark against oracle"; stale when `internal` is true |

Quote one, say which it is, and give the others beside it when they differ. A price of 0 or a missing price means "no price" (a halted or never-traded market), so fall back to the next one.

## The order book

`GET /clob/orderbook/{id}?depth=N`: the resting orders after the latest round. Omit `depth` for the whole book. A market that never cleared answers `404 no orderbook snapshot yet`.

| Field | Meaning |
|---|---|
| `buys`, `sells` | Objects keyed by price (a **decimal string** scaled by 10^18), each `{"volume": "0x…"}` (hex). Keys are in ascending price order; **the best bid is the last `buys` key and the best ask the first `sells` key**. Sort on the number, not the string |
| `buys_count`, `sells_count` | Levels in the whole book, even when `depth` cuts it |
| `clearing_price` | Hex. The current mark, carried forward on rounds without trades |
| `oracle_price` | Hex, perps (`null` on spot) |
| `funding_rate` | Signed decimal, perps |
| `timestamp` | The round, microseconds |

Spread = best ask − best bid; mid = their average.

## What a size would cost now

Pod clears each market **once per round at one price for everyone**. A market order of size S does not pay an average across levels: it clears at about the price of the **last level it needs**. For a buy, walk the asks from the best up, adding volumes until they cover S; that level's price is the estimate. For a sell, walk the bids down. Orders arriving in the same round can move it, so call it an estimate. If the book holds less than S, say how much it holds.

## Price bars (candles)

`GET /clob/candles/{id}?resolution=R&limit=N&from=S&to=S`: closed bars, newest first.

| Parameter | Meaning |
|---|---|
| `resolution` | Required: `1m`, `5m`, `15m`, `30m`, `1h`, `4h`, `1d`, `1w`, `1M` |
| `from`, `to` | **Unix seconds**, not microseconds. `[from, to)` |
| `limit` | Up to 500 |

Answer: `candles` (each `timestamp` µs, `open`, `high`, `low`, `close`, `volume` in units, `quote_volume` in USD, `oracle_price`; all hex), `range` (`from_us`, `to_us`: the oldest and newest bar's start), `solution_now_us`.

The bar still forming is not served, and it is dropped after `limit` applies: a page that reaches now holds one bar fewer than asked, so ask for one more. Older bars: `to = range.from_us / 1000000`. The forming bar can be built from the `pod_candles` channel ([live.md](live.md)).

## Per-round history (solutions)

`GET /clob/solutions?orderbook={id}&limit=N`: one row per round, newest first. `limit` counts rounds, up to 200. `since_us` and `until_us` bound the window (microseconds as decimal strings); older pages: `until_us` = the oldest `timestamp` of the page.

Fields: `timestamp`, `clearing_price`, `mark_price`, `oracle_price`, `volume`, `open_interest` (hex), `funding_rate`, `funding_index`, `premium_ema` (signed decimals), and the mark inputs `mark_best_bid`, `mark_best_ask`, `impact_bid`, `impact_ask`, `book_median_ema`. Rounds are half a second apart, so show their times with milliseconds.

## Network activity

| Goal | Call |
|---|---|
| The latest round number | JSON-RPC `eth_blockNumber` (hex). One round is one "block", two per second |
| One round and its transactions | JSON-RPC `eth_getBlockByNumber` `["0x…", false]`; its `timestamp` is hex **seconds** |
| Recent transactions, decoded | `GET /transactions?limit=N&offset=K` (`limit` up to 200; only the newest 1,000). Each has `decoded.function` (e.g. `submitBatch`, or `submitSolutionsV5`, the auction result of a round) |
| One transaction in full | `GET /tx/{hash}` |
