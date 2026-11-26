# Section 3: Account

*Spec, 2026-11-26. Decided in the interview of 2026-11-26. Branch `4-cli`: this section now runs as `pod` commands; see [08-cli-and-hook.md](08-cli-and-hook.md) for the command map and the approval hook. The decisions and findings below are unchanged.*

Account answers **"what does this account hold, what is it worth, and what has it done?"** for the connected wallet by default, or for any address. It only reads; no key is needed.

## Decisions

| # | Topic | Decision |
|---|---|---|
| A1 | How data is read | A script, `pod account`, calls pod's REST API and returns **plain numbers**: 10^18 amounts and hex turned into dollars and sizes, microseconds into dates, market ids into names, paging handled. `--raw` returns pod's answer unchanged |
| A2 | Numbers pod does not serve | **A few, computed and marked as computed**: per position, return on margin and distance to liquidation; per account, margin in use, free margin and real leverage. No advice or signals |
| A3 | Names for other accounts | **No.** Other accounts are named by their address |
| A4 | History | **Newest 50 entries** by default; `--since` for a time window and `--limit` for more, up to 5,000; paging handled by the script |
| A5 | Results over a period | **Yes**, a `results` view: plain totals over a window, marked as computed. No ratings, win rates or advice |
| A6 | Skills | **One command**, `pod account`, with one view per question (one skill in the hybrid) |

A raw comparison version (one skill, no scripts) is branch `1-raw`.

## Usage

```
pod account VIEW [ADDRESS] [--since 7d|24h|30m|2026-11-01] [--limit N] [--status S] [--raw]
```

`ADDRESS` defaults to the connected wallet. With no wallet connected and no address, the script stops with "name an address, or connect a wallet with pod setup".

## Views

| View | Answers | Pod calls | Computed (A2) |
|---|---|---|---|
| `overview` (default) | "What do I have?" | `/clob/positions/{a}`, `/clob/balances/{a}`, `/clob/orders/{a}?status=active` | Margin in use, free margin, real leverage |
| `positions` | "What are my open bets?" | `/clob/positions/{a}` | Return on margin %, distance to liquidation % |
| `orders` | "What orders are open?" Open by default; `--status` for others, `--status all` for history | `/clob/orders/{a}` | |
| `trades` | "What did I buy and sell?" | `/clob/fills/{a}` | |
| `triggers` | "Which stop-losses and take-profits are armed?" | `/clob/triggers/{a}` | |
| `activity` | "What happened on this account?" Orders, fills, cancels, expiries, deposits, transfers, forced closes | `/clob/activity/{a}` | |
| `forced-closes` | "Was I liquidated?" | `/clob/backstop-transfers/{a}` | |
| `results` | "How did the last 7 days go?" | `/clob/fills/{a}`, `/clob/positions/{a}` | All of it (below) |

Every view also reads `/clob/markets` once, to turn market ids into names such as "NVDA perp".

### Fields

**overview:** account value, cash, unrealized profit or loss, realized profit or loss (lifetime), withdrawable, net deposits; margin in use, free margin, real leverage (computed); number of open positions and orders; a one-line list of the positions.

**positions:** market, side, size, entry price, mark price, value, margin, pod's leverage figure, unrealized profit or loss, return on margin % (computed), funding paid or received so far, liquidation price (none when pod sends `0x0`), distance to liquidation % (computed), stop-loss and take-profit.

**orders:** market, side, type (limit or market), size, filled size, price, average fill price, status, flags (maker-only, immediate-or-cancel, reduce-only), fee, when it joined the book, when it ends, order id, transaction hash.

**trades:** time, market, side, size, price, value, fee, order id.

**activity:** time, kind, and a plain description ("order placed: buy 0.01 NVDA perp at $151.03", "order cancelled", "deposit: $100"), plus the original entry's ids.

### The computed numbers

| Number | How | Note |
|---|---|---|
| Margin in use | Sum of each position's `margin` | |
| Free margin | Account value − margin in use | Pod calls this "available margin": what can back new positions |
| Real leverage | Sum of position values ÷ account value | |
| Return on margin | Unrealized profit or loss ÷ margin | Per position |
| Distance to liquidation | (mark − liquidation price) ÷ mark, as %, for a long; the reverse for a short | None when pod gives no liquidation price |

### The results view

Over the window (`--since`, default 7 days):

| Total | Source | Note |
|---|---|---|
| Number of trades, amount bought and sold | Fills in the window | |
| Fees paid | Sum of the fills' fees | |
| Realized profit or loss, lifetime | Pod's `total_realized_pnl` | Served by pod |
| Unrealized profit or loss now | Pod's `total_unrealized_pnl` | Served by pod |
| Funding paid or received on open positions | Pod's `funding_accrued` per position | Pod has no funding history: closed positions' funding is not visible |
| Realized profit or loss within the window | Sum of the `pnl` pod records on each fill in the activity feed | Resolved while building: pod's activity fills carry "PnL realized by this fill alone", so no reconstruction is needed |

## Output

One JSON object:

```json
{"ok": true, "view": "positions", "account": "0x035A…", "connected": true, "as_of": "2026-11-26T15:00:00Z",
 "data": [ ... ], "count": 1, "more": false, "computed": ["return_on_margin_pct", "liquidation_distance_pct"]}
```

`more` is true when more history exists beyond `--limit`. `computed` names the fields pod worked out rather than read from pod.

## Facts found while specifying (live, 2026-11-26)

- Fills have no side field; the side comes from the sign of `initial_size` (positive is a buy).
- The activity feed's kinds seen: `order`, `fill`, `termination` (cancelled or expired), `bridge_transfer` (deposit). It has no funding entries.
- A liquidation price of `0x0` means the position has none at its current size and margin.
- The dev wallet's 0.01 NVDA long shows pod leverage 19.96 against a market maximum of 20.

## Implementation notes (2026-11-26)

Built in [cli](file:///Users/sabpap/Workspace/Clients/Laurium/pod-ai/cli/): `pod account` (`cli/libexec/account.sh`), `cli/libexec/pod.jq` (exact conversion of pod's numbers on digit strings, no floating point), `since_us` in `lib.sh`, and the `/pod:account` skill (in branch `4-cli`: the manual `pod account --help` and the one `pod` skill). Version 0.3.0.

| Finding | Effect |
|---|---|
| Pod's published API description ([openapi.yaml](https://github.com/podnetwork/pod-sdk/blob/main/doc/api-reference/rest/openapi.yaml)) documents every field | Used for triggers, forced closes and the activity kinds the dev wallet has not produced yet |
| Activity fills carry `pnl`, the profit or loss that fill realized | The results view's realized profit or loss for a period is pod's own figures added up |
| Lifetime profit or loss is `account_value − net_deposits`, per pod's own definition | Shown as `lifetime_pnl_usd` (computed) |
| Orders carry `direction` (open_long, reduce_short, …) and `realized_pnl` | Shown in the orders view |
| `funding_accrued`: positive means the holder owes it | Named `funding_owed_usd` |
| Pod's history service went down for a while (HTTP 503 "clob indexer unavailable") | Errors now pass pod's own reason on; overview, positions and orders kept working |
| Activity pages of 2,000 entries were too slow on a busy account | Pages of 500 |
| Review: every fill of an auction round shares one timestamp, so a page of trades could end mid-round and the next window (which ends before that timestamp) skipped the rest of it | Each page's oldest round is dropped and read again whole by the next window. Checked on the busy account: at each page boundary the script's count matched pod's own count for that second |
| Review: computed amounts above about $1 billion came out of jq as `1e+17` | Computed numbers keep at most 15 significant digits, so they never reach jq's exponent form |
| A market maker's transactions come from its bot key; the account it trades for is the first argument of the `delegated(...)` call | That account (54 perps, 6 spot holdings, 1,588 open orders) was the paging test |

Tested: 47 offline unit checks (including the jq conversions and `--since`), 38 read-only smoke checks against staging, and on the busy account: 600 open orders and 1,200 trades with no duplicates, 3,000 activity entries in 5.6 s across 6 pages, a 3-minute window cut to exactly 5,000 entries with `more: true`, and results over an hour (4,057 trades).

## Not part of Account

Placing or cancelling anything (Trading), live updates (Live), market prices beyond each position's mark (Market data), saved names for other accounts (A3).
