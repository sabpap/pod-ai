---
name: live
description: Follow pod network live - watch a market's price, the order book, price bars, an account's orders, positions, stop-losses and activity, transaction receipts or the auction rounds as they change, and get told the moment a condition holds (a price crosses a level, an order fills, a position closes). Use when the user asks to watch, monitor, follow, stream or keep an eye on something on pod, to be told when something happens, or to do something when a condition is met; and to list or stop running watches.
argument-hint: "market|book|bars|orders|positions|triggers|activity|receipts|rounds ... [--until \"FIELD OP VALUE\"] | list | stop ID|all"
---

# Live updates on pod

A listener holds pod's WebSocket open and prints **one JSON line per update**. It only reads and never trades. It runs until a condition holds, `--for` runs out, it is stopped, or the session ends.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/live.sh" CHANNEL [MARKET... | ADDRESS] [--until "FIELD OP VALUE"] [--every 30s] [--for 2h]
```

It needs Node.js 22 or later; `/pod:status` says whether "follow live updates" is available. Below, `live.sh` is short for `"${CLAUDE_PLUGIN_ROOT}/scripts/live.sh"`: always run it by its full path.

## How to run it in Claude Code

A listener is long-running, so **never run it in the foreground** without `--for`.

| The user wants | How |
|---|---|
| **To be told when something happens**: "tell me when NVDA drops below 140", "let me know when my order fills" | Bash with `run_in_background: true` and `--until`. You are woken once, when it ends. Read its last line: `"event": "condition met"` with the row that matched |
| **"Watch X and if this happens, do that"** | The same, then do "that" with the other skills. A trade still goes through `/pod:trade`, which asks for approval unless the approval setting is `auto` |
| **A running commentary**: "keep me posted on NVDA for the next half hour" | The Monitor tool with `command: live.sh market NVDA --for 30m` and `timeout_ms: 1800000`. Every line becomes a message. A Monitor lasts at most 30 minutes: for longer, start it again when it expires |
| **Watch now, look later**: "follow my positions, I'll ask later" | Bash `run_in_background: true` without `--until`; read its output file when the user asks |
| A one-off look | Not a listener: use `/pod:markets` or `/pod:account` |

Tell the user what is running in one line, from the first line the listener prints (`"event": "watching"`): what it watches, the condition, how often it reports, and its `id`. Stop listeners the user no longer needs:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/live.sh" list          # what is running on this machine
"${CLAUDE_PLUGIN_ROOT}/scripts/live.sh" stop ID       # or: stop all
```

## Channels

| Channel | Follows | Reports by default |
|---|---|---|
| `market NVDA [GOLD ...]` | Price (mark on perps, last traded on spot), 24-hour numbers, funding, open interest | Changes, at most every 30 s |
| `book NVDA ...` | Best bid and ask, spread; `--depth N` adds N levels per side | Changes, at most every 30 s |
| `bars NVDA ...` | One price bar (open, high, low, close, volume) per `--every` window, built from each round | One bar per 30 s in which something traded or the price moved |
| `orders [ADDRESS ...]` | Order events: new, filled (partly or fully), cancelled, expired, refused, changed. Up to 64 accounts | Every change |
| `positions [ADDRESS]` | Account value, cash and the positions; with `--market NVDA`, that one position | Every change, starting with the current state |
| `triggers [ADDRESS]` | The armed stop-losses and take-profits | Every change, starting with the current list |
| `activity [ADDRESS]` | Everything that happens on the account, each with a plain description | Every change |
| `receipts --tx HASH ...` | Whether sent transactions succeeded; ends by itself when every one has arrived | Every receipt |
| `rounds` | Pod's auction rounds (two a second) | Count per 30 s |

`ADDRESS` defaults to the connected wallet. `--market NAME` narrows an account channel to one market, `--order ID` narrows orders or activity to one order. `--every 5s` reports faster, `--every 0` reports every update (two a second on a busy market: too many for Monitor).

## Conditions

`--until "FIELD OP VALUE"` ends the listener on the first update where it holds. Repeat `--until` for "any of these". Operators: `<`, `<=`, `>`, `>=`, `=`, `!=`. Numbers compare as numbers; text compares without case. Conditions are tested on every update, whatever `--every` says.

| Channel | Fields (short names in brackets) |
|---|---|
| `market` | `price`, `mark_price` (mark), `last_price` (last), `oracle_price` (oracle), `change_24h_pct` (change), `funding_rate_pct` (funding), `mark_vs_oracle_pct`, `open_interest_usd`, `volume_24h_usd`, `high_24h`, `low_24h`, `status` |
| `book` | `best_bid` (bid), `best_ask` (ask), `mid`, `spread`, `spread_pct`, `bid_size`, `ask_size` |
| `bars` | `price`, `volume` (of each round) |
| `orders` | `status` (resting, partly filled, filled, canceled, expired, refused), `event`, `side`, `fill_price`, `filled_size`, `total_filled`, `order_id` |
| `positions` | `account_value_usd`, `cash_usd`, `unrealized_pnl_usd` (pnl), `positions`; with `--market`: `size`, `side`, `mark_price`, `unrealized_pnl_usd`, `liquidation_distance_pct` |
| `triggers` | `count` |
| `activity` | `kind` (order, fill, termination, …), `status`, `position_after`, `realized_pnl_usd` |
| `receipts` | `ok` |
| `rounds` | `round` |

Examples:

- "Tell me when NVDA trades below 140": `live.sh market NVDA --until "mark < 140"`
- "Let me know when order 0xab… fills": `live.sh orders --order 0xab… --until "status = filled"`
- "Tell me if my NVDA position gets closed": `live.sh positions --market NVDA --until "size = 0"`
- "Warn me if I get within 5% of liquidation": `live.sh positions --market NVDA --until "liquidation_distance_pct < 5"`
- "Alert me if the gold spread widens past 0.5%": `live.sh book gold --until "spread_pct > 0.5"`

A stop-loss or take-profit on a position does not need a listener: pod watches it on its own side (`/pod:trade stop-loss`).

## Lines it prints

| Line | Meaning |
|---|---|
| `"event": "watching"` | First line: `id`, `channel`, `what`, `until`, `every`, `for`, and the stop command |
| An update | Plain numbers, like `/pod:markets` and `/pod:account`: amounts as exact decimal strings, times in UTC |
| `"event": "notice"` | The connection dropped or pod closed the stream. The listener reconnects by itself and catches up from the last round it saw, so nothing is missed; if pod no longer holds the missed rounds, it says so |
| `"event": "condition met"` | Last line: the `condition` and the row that matched |
| `"event": "stopped"` | Last line: `reason` (time up, stopped on request, every receipt arrived) |
| `"ok": false` | Refused before starting, with `error` and `fix` |

## For other harnesses: pod's live protocol

A harness without background processes can run `live.sh` itself, or talk to pod directly:

- Connect to `wss://staging-rpc.podtestnet.dev` and send `{"jsonrpc":"2.0","id":1,"method":"eth_subscribe","params":["<channel>",{options}]}`. Updates arrive as `eth_subscription` notifications after each auction round.
- Channels: `pod_markets`, `pod_orderbook` (`depth`), `pod_candles`, `pod_orders_v2` (`bidder` or `bidders`, up to 64), `pod_activity`, `pod_positions`, `pod_triggers` (these three need `account`), `pod_receipts` (`account` or `tx_hashes`), `newHeads`. Market channels take `orderbook_ids` from `/pod:markets`.
- Numbers are 10^18-scaled, hex or decimal; times are microseconds.
- No gaps: read the REST view first, note its `solution_now`, and subscribe with `since` set to it. Pod replays every round after it (about 2.3 hours are kept; older is refused with "since too old"). State channels (`pod_markets`, `pod_positions`, `pod_triggers`) send the current state at once when given `since`.
- When pod closes a stream, the notification carries `error.data.resume_since` (and `resume_since_book` on `pod_orders_v2`): subscribe again with them.
