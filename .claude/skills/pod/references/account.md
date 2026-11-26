# Account: what an account holds and has done

Every route here is a public `GET` on `https://staging-rpc.podtestnet.dev/v1`. Any address can be read; no key is needed. The connected wallet's address comes from `pod-send.sh --check`. Numbers follow [basics.md](basics.md): convert every amount with `pod-number.sh from-pod`.

## Contents

- [Pick the route from the question](#pick-the-route-from-the-question)
- [Positions and the account's value](#positions-and-the-accounts-value)
- [Balances and spot holdings](#balances-and-spot-holdings)
- [Orders](#orders)
- [Trades (fills)](#trades-fills)
- [Triggers](#triggers)
- [Activity](#activity)
- [Forced closes](#forced-closes)
- [Numbers worth working out](#numbers-worth-working-out)
- [Account health and nonces](#account-health-and-nonces)

## Pick the route from the question

| The user asks | Route |
|---|---|
| "What's my balance?", "how much do I have?" | `/clob/positions/{a}` (account value, cash, profit or loss) and `/clob/balances/{a}` |
| "What are my positions?", "am I near liquidation?" | `/clob/positions/{a}`; spot holdings in `/clob/balances/{a}` |
| "What orders are open?" | `/clob/orders/{a}?status=active` and `?status=pending` |
| "Order history", "why was my order refused?" | `/clob/orders/{a}` (any status), `/clob/activity/{a}` |
| "What did I buy and sell?", "fees paid?" | `/clob/fills/{a}` |
| "Which stop-losses and take-profits are set?" | `/clob/triggers/{a}` |
| "What happened on my account?", "profit this week?" | `/clob/activity/{a}` |
| "Was I liquidated?" | `/clob/backstop-transfers/{a}`, and orders with `kind` `liquidation` |
| "Is my account stuck?", "which nonce is free?" | `pod_getAccountDiagnostics`, `/accounts/{a}/nonce-slots` |

```bash
A=0x035A9E2f3ED8bAAD656E66BF3f0071da40DcDa70
V=https://staging-rpc.podtestnet.dev/v1
curl -s "$V/clob/positions/$A" | jq '{account_value, cash, total_unrealized_pnl, n: (.positions | length)}'
```

Market ids in these answers (`orderbook_id`, `book`) become names through `GET /v1/clob/markets` ([markets.md](markets.md#the-market-list-and-its-rules)).

## Positions and the account's value

`GET /clob/positions/{a}`: the open perp positions and the account totals. An unknown account answers an empty list and zeros.

| Field | Meaning |
|---|---|
| `account_value` | **What the account is worth**: cash adjusted for funding, plus unrealized profit or loss, plus spot holdings at their price. This answers "how much do I have" |
| `cash` | Cash only. Opening a perp holds part of it as margin, so cash barely moves when a position opens: do not quote cash as the balance |
| `withdrawable_cash` | What could be withdrawn or transferred now (hex) |
| `total_unrealized_pnl`, `total_realized_pnl` | Open profit or loss now; realized lifetime, spot and perp |
| `net_deposits` | Deposited minus withdrawn. Lifetime profit or loss is `account_value − net_deposits` |
| `perps_equity` | Cash adjusted for funding, plus perp unrealized profit or loss |
| `timestamp` | The round this state belongs to (use as `since` on the WebSocket) |

Each entry in `positions`:

| Field | Meaning |
|---|---|
| `orderbook_id`, `base_symbol` | The market |
| `side` | `long` or `short` |
| `size` | Signed decimal: positive long, negative short. In units of the asset |
| `entry_price`, `mark_price` | Hex. The mark is what the position is valued and liquidated at |
| `notional` | Value at the mark (hex) |
| `margin` | Collateral held for it (hex) |
| `leverage` | Pod's figure for this position alone, value ÷ margin (hex, scaled by 10^18) |
| `unrealized_pnl` | Signed decimal |
| `funding_accrued` | Signed decimal. **Positive means the holder owes it** |
| `liquidation_price` | Hex. **`0x0` means none** at the current size and margin |
| `realized_pnl`, `stop_loss`, `take_profit` | Always `"0"` and `null` here. Realized profit is in `total_realized_pnl`; triggers are on their own route |

Example from staging: `"entry_price": "0x82ff658cf0b3f0000"` is $151.03, `"margin": "0x10c487e0e36b000"` is $0.075515, `"liquidation_price": "0x0"` is "no liquidation price", not $0.

## Balances and spot holdings

`GET /clob/balances/{a}`: `cash`, `withdrawable_cash`, `net_deposits`, `timestamp`, and `balances`, one entry per spot holding:

| Field | Meaning |
|---|---|
| `orderbook_id`, `base_symbol` | The spot market |
| `balance` | `free_balance + locked_balance` (hex) |
| `locked_balance` | Held by open sell orders |
| `cost_basis`, `mark_price`, `unrealized_pnl` | What was paid, the price now, the difference |

Pod's transaction fee is paid from the account's cash, so an account with no cash cannot send anything.

## Orders

`GET /clob/orders/{a}`: the account's orders with their fills, newest first.

| Parameter | Meaning |
|---|---|
| `status` | One of `pending`, `active`, `filled`, `expired`, `canceled`, `margin_canceled`, `self_trade_canceled`, `post_only_refused`, `settled`, `invalid`. Unknown is a `400` |
| `orderbook` | One market id |
| `limit` | Up to 500 |
| `cursor` | `next_cursor` of the previous page (`null` on the last) |
| `offset` | Instead of a cursor: skip this many; page while `offset < total_count` |
| `until` | Upper bound on the deadline, **in seconds**, first page only |

"Open orders" means `status=active` plus `status=pending`: ask for both. `total_count` gives the number without paging.

| Status | Meaning |
|---|---|
| `pending` | Sent, its round has not come |
| `active` | Resting in the book |
| `filled` | Completely filled |
| `expired` | Its end time passed, or the unfilled rest of an immediate-or-cancel order |
| `canceled` | Cancelled by the owner |
| `margin_canceled` | Removed: not enough margin |
| `self_trade_canceled` | Removed: it would have traded with the same account's order |
| `post_only_refused` | A maker-only order that would have crossed the book |
| `settled` | Refunded because its market was settled |
| `invalid` | Refused at execution; `invalid_reason` says why |

Everything except `pending` and `active` is final.

Fields of an order: `order_id`, `tx_hash`, `nonce`, `orderbook_id`, `market_type` (spelled `perpetual` here, `perp` in the market list), `kind` (`user_signed`, `liquidation`, `triggered`, `adl`, `adl_counterparty`, `backstop_transfer`), `order_type` (`limit` or `market`), `side` (`buy` or `sell`), `direction` (`open_long`, `reduce_short`, …), `price` (hex), `initial_size` (signed decimal), `filled_base_amount` and `filled_quote_amount` (hex), `effective_price` (average fill price, hex), `fee` (hex), `realized_pnl` (perps, signed), `deadline` (string, µs), `end` (number, µs; 2^64 − 1 is never), `included_batch` (the round it entered; can be earlier than `deadline`), `fills` (each with `base_amount`, `quote_amount`, `price`, `timestamp`), flags `reduce_only`, `ioc`, `post_only`, and for a fired trigger's order `trigger_type`.

## Trades (fills)

`GET /clob/fills/{a}`: one row per fill, newest first.

| Parameter | Meaning |
|---|---|
| `from_us`, `to_us` | The window `[from_us, to_us)`, microseconds. `to_us` defaults to now |
| `orderbook` | One market id |
| `limit` | 1 to 500 |

**There is no cursor and at most 500 rows per window.** To read further back, move the window: see [paging style 2](basics.md#paging-six-styles). "My last 200 trades" is one call with `limit=200`; "every trade this month" needs several windows.

Fields: `orderbook_id`, `order_id`, `order_type`, `initial_size`, `base_amount`, `quote_amount`, `price`, `fee` (hex), `timestamp`. **There is no side field: the side is the sign of `initial_size`** (positive is a buy). The price is the round's clearing price: every fill of one market in one round has the same price.

## Triggers

`GET /clob/triggers/{a}`: armed stop-losses and take-profits. `limit` 1 to 200, `cursor` from `next_cursor`, optional `orderbook`.

| Field | Meaning |
|---|---|
| `order_id` | The trigger's id, used to change or cancel it |
| `trigger_type` | `take_profit` or `stop_loss` |
| `trigger_price` | Hex. The mark price that fires it |
| `limit_price` | Hex. The price of the order it places when it fires |
| `size` | Signed decimal. **`"0"` with `grouping: "asset"` means the whole position**, long or short, sized when it fires |
| `grouping` | `asset`: removed when the position closes. `none`: stays until cancelled, expired or fired |
| `reduce_only`, `ioc` | Flags of the order it places |
| `deadline`, `end` | Microseconds |

## Activity

`GET /clob/activity/{a}`: everything that happened, grouped by round: `{"activity": {"<round µs>": [entries]}, "next": "...", "solution_now": ...}`.

| Parameter | Meaning |
|---|---|
| `from`, `to` | Round times, **microseconds**, both inclusive |
| `limit` | Entries per page, 1 to 2000 (default 500). A page can exceed it by its newest round |
| `activity_types` | Comma list: `order`, `fill`, `modify`, `termination`, `backstop`, `settlement`, `bridge_transfer`, `transfer`, `modify_reject`, `cancel_reject` |

Page with `to = next` until `next` is `null`. Amounts in entries are decimal strings scaled by 10^18. Entries by `k`:

| `k` | Fields | Meaning |
|---|---|---|
| `order` | The order, as `/clob/orders` serves it | An order entered (in its current state) |
| `fill` | `id`, `book`, `b` (base), `q` (quote), `f` (fee), `tb`/`tq`/`tf` (order totals so far), `st` (final status, on the last fill), `pa` (position after), `pnl` (profit realized by this fill) | A fill. Add `b` and `q`; the `t…` fields are running totals, not per fill |
| `modify` | `id`, `book`, `px`, `sz`, `old_px`, `old_sz` | An order's price or size changed |
| `termination` | `id`, `book`, `st`, `expr` (`ttl` or `ioc`) | An order left the book without filling |
| `modify_reject`, `cancel_reject` | `id`, `book`, `why` | A change or cancel pod refused; the order is untouched |
| `backstop` | `book`, `sz`, `cash`, `mark`, `eq`, `pnl` | A forced close into the backstop (no `book`: the final cash sweep) |
| `settlement` | `book`, `sz`, `px`, `pnl` | A position closed because its market was settled |
| `bridge_transfer` | `tx`, `tok`, `amt`, `err` | A deposit (positive) or withdrawal (negative); `err` means refused |
| `transfer` | `id`, `cp`, `tok`, `amt`, `err` | A transfer between pod accounts, signed from this account's side |

**Profit or loss over a period** is the sum of the `pnl` of the `fill` entries in the window (`activity_types=fill&from=…`). Lifetime figures come from `/clob/positions` directly. Pod keeps no funding history: funding paid on closed positions cannot be read.

Ignore kinds and fields you do not know; pod adds new ones without notice.

## Forced closes

`GET /clob/backstop-transfers/{a}`: positions swept to the backstop. With no parameters, the whole list up to 500. With `limit`, `cursor` or `orderbook`, pages of up to 200 with `next_cursor`. Fields: `orderbook_id` (missing on the cash-sweep row), `size`, `cash`, `mark_price`, `equity`, `realized_pnl` (decimal strings), `timestamp_us`.

## Numbers worth working out

Pod does not serve these. Work them out from the fields above and say they are worked out.

| Number | How |
|---|---|
| Margin in use | Sum of each position's `margin` |
| Free margin | `account_value` − margin in use. What can back new positions |
| Real leverage | Sum of the positions' `notional` ÷ `account_value` |
| Return on margin | `unrealized_pnl` ÷ `margin`, per position |
| Distance to liquidation | Long: (mark − liquidation) ÷ mark. Short: (liquidation − mark) ÷ mark. None when the liquidation price is `0x0` |
| Lifetime profit or loss | `account_value − net_deposits` |
| Funding per year | `funding_rate` × (one year ÷ `funding_window_us`). 0.01% per 8 hours is 10.95% a year |

Convert each amount exactly first, then compute; rounding the result for display is fine.

## Account health and nonces

| Question | Call |
|---|---|
| Is the account frozen? | JSON-RPC `pod_getAccountDiagnostics` `["0xADDRESS"]`: `is_locked`, `needs_recovery` and `equivocating` should all be `false`. Recovery is outside this skill |
| Which nonces are free? | `GET /accounts/{a}/nonce-slots` (or JSON-RPC `pod_getNonceSlots`): `{"watermark": 50, "finalized": "0x0", "solution_now": …}`. Any nonce in `[watermark, watermark + 128)` whose bit in `finalized` is not set can be used |
| The next nonce to sign with | JSON-RPC `eth_getTransactionCount` `["0xADDRESS", "pending"]` (hex). `pod-send.sh` uses this |
| Did a transaction go through? | JSON-RPC `pod_getTxStatus` `["0xHASH"]`: `not_found`, `pending`, or `finalized` with `success` |
| A transaction in full, decoded | `GET /tx/{hash}`: fields, receipt, and `decoded` (function, arguments, `order_id`) |
