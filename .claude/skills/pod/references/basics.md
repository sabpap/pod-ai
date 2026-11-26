# Basics: how pod talks

Read this before any other reference. Every other file assumes it. In all references, `pod-number.sh` and `pod-send.sh` are the two scripts in this skill's `scripts/` folder: run them by their full path.

## Contents

- [Network](#network)
- [Identifiers](#identifiers)
- [Numbers](#numbers)
- [Zero means none](#zero-means-none)
- [Times](#times)
- [Rounds: accepted is not filled](#rounds-accepted-is-not-filled)
- [The `timestamp` freshness parameter](#the-timestamp-freshness-parameter)
- [Paging: six styles](#paging-six-styles)
- [Errors](#errors)
- [Pod's own docs](#pods-own-docs)

## Network

Pod is a trading network: perpetual futures ("perps") and spot markets, matched in auctions twice a second. This skill works on **pod staging only**, a test network with play money that is reset from time to time.

| What | Value |
|---|---|
| Chain id | `129302` (hex `0x1f916`) |
| REST (read-only `GET`) | `https://staging-rpc.podtestnet.dev/v1` |
| JSON-RPC (`POST`, any path) | `https://staging-rpc.podtestnet.dev` |
| WebSocket | `wss://staging-rpc.podtestnet.dev` |
| Order book contract (every trading call goes here) | `0x50d0000000000000000000000000000000000002` |
| USD token (the quote token of every market) | `0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee` |

Check the network before sending: `eth_chainId` must answer `0x1f916`, and `pod_status` must answer `{"read_only": false, "paused": false}`. `pod-send.sh` checks the chain id itself.

```bash
curl -s https://staging-rpc.podtestnet.dev -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"pod_status","params":[]}'
```

Reading needs no key: every account's data is public. Only sending needs a wallet.

## Identifiers

| Thing | Form | Example |
|---|---|---|
| Account | 20-byte address, `0x` + 40 hex. Pod answers in lower case; compare without case | `0x035a9e2f3ed8baad656e66bf3f0071da40dcda70` |
| Market | 32-byte market id ("orderbook id"), `0x` + 64 hex. Called `id` in the market list, `orderbook_id` elsewhere, `book` in compact frames | NVDA perp is `0x0000000000000000000000000000000000000000000000000000000000000007` |
| Market name | `base_token_symbol` (`NVDA`), `name` (`NVDA/USD`), `base_token_name` (`Nvidia Perpetual`), `market_type` (`perp` or `spot`) | A ticker can have a perp and a spot market. Spot symbols end in `x` (`GLDx` is gold spot, `GLD` gold perp) |
| Order id | `keccak256(abi.encode(address signer, uint64 nonce, uint32 sequence))`. **Not the transaction hash.** `sequence` is the position inside a `submitBatch` (0 for a single call). A trigger's id is made the same way | `cast keccak $(cast abi-encode 'f(address,uint64,uint32)' 0xSIGNER 47 0)` |
| Transaction hash | 32 bytes, `0x` + 64 hex | |

Market ids never change, but look them up in `GET /v1/clob/markets` rather than guessing.

## Numbers

**Amounts and prices are integers scaled by 10^18.** 151.03 dollars is `151030000000000000000`. A size of 0.01 NVDA is `10000000000000000`.

Pod mixes three forms, sometimes in one answer:

| Form | Where | Example |
|---|---|---|
| `0x` hex, unsigned | Most amounts and prices on orders, fills, positions, candles, rounds, book volumes | `"entry_price": "0x82ff658cf0b3f0000"` (151.03) |
| Decimal string, signed | Sizes, profit and loss, funding, cash, account value | `"size": "-10000000000000000"` (a 0.01 short) |
| Decimal string, unsigned | The market list, market stats, activity entries, book price keys | `"mark_price": "150178932253596000000"` |

**Never convert these with floating point** (JavaScript `Number`, Python `float`, jq arithmetic). A double holds about 15 to 16 significant digits; these values have 20 or more and often pass 2^64. Use the skill's converter, which is exact:

```bash
pod-number.sh from-pod 0x82ff658cf0b3f0000 -2648957182430000   # 151.03, -0.00264895718243
pod-number.sh to-pod 151.03 -0.01                              # 151030000000000000000, -10000000000000000
pod-number.sh int 0x32                                         # 50 (hex integer, not scaled)
```

Integer arithmetic on the scaled values (rounding, value of an order) is exact with `bc`. jq 1.7 compares and adds big integers as doubles, so do not do money arithmetic in jq either.

Not every number is scaled by 10^18:

| Field | Meaning |
|---|---|
| `maker_fee`, `taker_fee` | A plain decimal fraction: `"0.000450"` is 0.045% |
| `price_change_24h` | Basis points, a JSON integer: `228` is +2.28% |
| `max_leverage` | Plain integer: `20` |
| `initial_margin` | A rate scaled by 10^18: `50000000000000000` is 5% |
| `funding_rate` | A rate scaled by 10^18 per `funding_window_us`: `100000000000000` is 0.01% per 8 hours |
| `auction_interval_us`, `funding_window_us` | Microseconds |
| `nonce`, `watermark`, `total_count`, `buys_count` | Plain integers |
| `lot_size`, `tick_precision`, `min_notional` | Scaled by 10^18, like amounts. NVDA perp: price step `10000000000000000` (0.01), size step `1000000000000` (0.000001) |

## Zero means none

Pod often sends 0 where it has no value. Read it as "none", never as zero dollars:

- `"liquidation_price": "0x0"`: the position has no liquidation price at its current size and margin.
- A `mark_price` or `last_clearing_price` of 0 on a halted or never-traded market: no price.
- `"clearing_price": "0x0"` on a book: the market has not cleared yet.
- `"included_batch": 0` on an order: engine-generated, or an old row.
- A trigger `size` of `"0"` with grouping `asset`: the whole position, sized when it fires.
- `"end": 18446744073709551615` (2^64 − 1): never expires.

Optional fields are left out until pod has data (for example `last_clearing_price` before a market's first trade). A missing field is not zero either.

## Times

**Pod counts time in microseconds since 1970** (16 digits today, e.g. `1795710282500000`). A deadline, a `ttl`, a `since`, `from_us`, `solution_now`: all microseconds. The exceptions are traps:

| Field | Unit |
|---|---|
| Candles `from` and `to` | **Seconds** |
| Orders `until` | **Seconds** |
| `newHeads` and `eth_getBlockByNumber` `timestamp` | **Seconds, hex** |
| Everything else | Microseconds |

Times come as JSON numbers in some fields and decimal strings in others (an order's `deadline` is a string, its `end` a number; activity keys are strings). Both are microseconds.

```bash
pod-number.sh time 1795710282500000          # 2026-11-26T16:24:42.500Z
pod-number.sh us 2026-11-26T16:24:42.500Z    # 1795710282500000
pod-number.sh us now                         # now, in microseconds
```

`pod-number.sh time` refuses a 10-digit or 13-digit value, because that is seconds or milliseconds passed by mistake.

## Rounds: accepted is not filled

Pod matches orders in **batch auctions**, one round every `auction_interval_us` (500,000 µs, half a second, on every staging market). In one round, each market clears **at one price for everyone**. A round is also called a batch or a tick; its time (its deadline) identifies it.

The life of an order:

1. You sign a transaction and send it with `eth_sendRawTransaction`. Pod answers with the transaction hash.
2. `pod_getTxStatus` says `"status": "finalized", "success": true`. **The transaction was accepted. Nothing has traded yet.**
3. The order enters a round no later than its `deadline` (it may land a round or more earlier). Only then does it fill, rest in the book, or get refused.
4. The outcome is in `GET /v1/clob/orders/{account}`: `status` is `pending`, then `active` (resting), `filled`, or a refusal such as `post_only_refused` or `margin_canceled`. See [trading.md](trading.md#7-read-the-real-outcome).

So never report "bought" after the send. Report "sent, accepted", then the outcome once the round has passed.

`GET /v1/clob/status` gives `solution_now`: the time of the newest round the indexer has handled.

## The `timestamp` freshness parameter

Pod is served by several nodes that may be a round behind each other. Most REST routes take `?timestamp=MICROS`: "answer only once your data has reached this round". The node waits up to 2 seconds, then answers `503` with a JSON body `{"timestamp": <its current value>}` and `Retry-After: 1`.

Use it to read your own writes: after you see a round time (a `solution_now`, a position's `timestamp`, a receipt's `timestamp_us`), pass it on the next read, so the answer is at least that new. A value far in the future is refused at once with `503`. The same idea is `since` on `GET /v1/accounts/{account}/nonce-slots` and on the state channels of the WebSocket ([live.md](live.md)).

## Paging: six styles

Each route pages its own way. Getting this wrong silently loses or repeats entries.

| # | Routes | How to get the next page |
|---|---|---|
| 1 | `/clob/orders/{a}` (≤ 500), `/clob/triggers/{a}` (≤ 200), `/clob/backstop-transfers/{a}` (≤ 200 once `limit` or `cursor` is set) | Pass `next_cursor` back as `cursor`. `null` (or missing) means the last page. Orders also take `offset` instead |
| 2 | `/clob/fills/{a}` | **No cursor.** A time window `[from_us, to_us)`, at most 500 rows, newest first. Every fill of one round shares one timestamp, and a full page can end in the middle of a round. So: drop the page's oldest round from what you keep, and ask for the next window with `to_us` = that oldest `timestamp` + 1, which reads that round again whole |
| 3 | `/clob/activity/{a}` | Pass `next` back as `to`. Pages hold whole rounds; `limit` up to 2000 (500 is safer on busy accounts). `null` means no more |
| 4 | `/clob/candles/{id}` | `to` = `range.from_us / 1000000` (**seconds**). `limit` ≤ 500. The bar still forming is dropped after the limit, so a page reaching now has one bar fewer |
| 5 | `/clob/solutions` | `until_us` = the oldest `timestamp` on the page. `limit` ≤ 200 rounds |
| 6 | `/transactions` | `offset` = `next_offset`. Only the newest 1,000 transactions exist here; older ones are only at `/tx/{hash}` |

Details per route are in [account.md](account.md) and [markets.md](markets.md).

## Errors

### REST

| Status | Meaning |
|---|---|
| `400` | A malformed parameter (bad hex, wrong length, unknown status). The body is a plain-text reason |
| `404` | `no orderbook snapshot yet` (the market never cleared), or `transaction not found` |
| `422` | Activity with `from` later than `to` |
| `503` | `clob indexer unavailable`: pod's history service is down. Positions, balances and the order book usually still work. Or, with `timestamp`, the node is behind (JSON body, retry after 1 s) |

### JSON-RPC

| Code | Meaning | What to do |
|---|---|---|
| `3` | `execution reverted`: the order book refused the call. `data` is an ABI-encoded `Error(string)`; `pod-send.sh` decodes it, e.g. `CLOB validation failed: Deadline is not aligned to auction interval` | Fix what the reason names |
| `-32000` | `transaction validation failed`; `data` holds the reason: `Insufficient balance`, `Invalid chain ID: …`, `Transaction is blacklisted`, `Underpriced tx: …` | Depends on the reason. Blacklisted does not pass |
| `996` | A nonce problem: `Past nonce`, `Future nonce`, or `Account has pending transaction` (`data`: `past_nonce`, `future_nonce`, `account_pending`). Nothing was broadcast | Check `pod_getTxStatus` of any earlier attempt, then send again with a fresh `pending` nonce |
| `995` | `node behind requested timestamp` (a `timestamp`, a `since`, or a block number was ahead of the node) | Retry |
| `-32003` | Rejected by a quorum of validators; `data` lists the reasons | Fix and send a new transaction |
| `-32025` | `not available in your region` | Lasting: this wallet cannot trade from here |
| `-32602` | Invalid params, including a WebSocket `since` that is too old or not a number | Fix the parameter |
| `-32020` to `-32026` | A subscription closed by the server (arrives as a notification, see [live.md](live.md#when-pod-closes-a-stream)) | Resubscribe from `resume_since` |

Order-book refusals seen inside reverts or order statuses: `Deadline is not aligned to auction interval`, `post-only order cannot be immediate-or-cancel`, `post-only is not valid for a market order`, `market orders must be immediate-or-cancel`, `market disables at …: an intent with deadline … could never execute`.

## Pod's own docs

The source for anything not covered here:

- REST routes and every field: [rest/openapi.yaml](https://github.com/podnetwork/pod-sdk/blob/main/doc/api-reference/rest/openapi.yaml)
- JSON-RPC methods and WebSocket channels: [json-rpc/openapi.yaml](https://github.com/podnetwork/pod-sdk/blob/main/doc/api-reference/json-rpc/openapi.yaml)
- Error codes: [json-rpc-errors.md](https://github.com/podnetwork/pod-sdk/blob/main/doc/api-reference/json-rpc-errors.md)
- The order book contract, flags and ABI: [orderbook.md](https://github.com/podnetwork/pod-sdk/blob/main/doc/api-reference/applications-precompiles/orderbook.md)
- Guides (perp orders, batches, parallel sends): [api-reference/guides](https://github.com/podnetwork/pod-sdk/tree/main/doc/api-reference/guides)

The JSON-RPC `ob_` methods are deprecated; use REST for reading.
