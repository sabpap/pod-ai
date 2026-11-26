# Account: what an account holds and has done

Read this for questions about what a pod account holds, what it is worth and what it has done: balance and account value, open positions with profit or loss, margin and liquidation price, open and past orders, trades and fees, stop-loss and take-profit triggers, activity history, forced closes, and results over a period such as the last 7 days. It works for the connected wallet or any other address.

Run:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/account.sh" [VIEW] [ADDRESS] [--since 7d] [--limit N] [--status S] [--raw]
```

`VIEW` is one of `overview` (the default), `positions`, `orders`, `trades`, `triggers`, `activity`, `forced-closes`, `results`.

`ADDRESS` defaults to the connected wallet. Any address can be read: pod's account data is public, and no key is needed. Nothing here sends a transaction.

## Pick the view from the question

| The user asks | View | Pod route behind it |
|---|---|---|
| "What do I have?", "what's my balance?" | `overview` (default) | `/clob/positions`, `/clob/balances`, `/clob/orders` |
| "What are my positions?", "am I close to liquidation?" | `positions` | `/clob/positions`, `/clob/balances` |
| "What orders are open?" | `orders` | `/clob/orders` |
| "What did I buy and sell?", "what did I pay in fees?" | `trades` | `/clob/fills` |
| "Which stops and targets are set?" | `triggers` | `/clob/triggers` |
| "What happened on my account?" | `activity` | `/clob/activity` |
| "Was I liquidated?" | `forced-closes` | `/clob/backstop-transfers` |
| "How did this week go?", "profit or loss since Monday?" | `results` | `/clob/activity`, `/clob/positions` |

## Options

| Option | Meaning | Views |
|---|---|---|
| `--since 7d` | Only entries after this time: `30m`, `24h`, `7d`, `2026-11-01`, `2026-11-01T12:00:00Z` (UTC) | trades, activity, results (default 7d) |
| `--limit N` | How many entries, 1 to 5000. Default 50, newest first | orders, trades, triggers, activity, forced-closes |
| `--status S` | `open` (default), `all`, or one of `pending active filled expired canceled margin_canceled self_trade_canceled post_only_refused settled invalid` | orders |
| `--raw` | Pod's answers unchanged, page by page. Only when the user asks for pod's own data, or a field is needed that the views leave out | all |

When `more` is true, there are more entries than were returned: say so, and offer a larger `--limit` or a `--since`.

## How to read the numbers

- Amounts are exact decimal strings, in USD (`_usd`) or in units of the asset (`size`).
- **Account value** is what the account is worth: cash plus unrealized profit or loss (and spot holdings at their price). It answers "how much do I have". **Cash** alone does not: a perp position only holds part of the cash as collateral (margin).
- `computed` lists the fields the plugin worked out from pod's data rather than read from pod: margin in use, free margin, real leverage, lifetime profit or loss, return on margin, distance to liquidation, and the results totals. Say "about" or "worked out from pod's data" when quoting them.
- `liquidation_price: null` means the position has none at its current size and margin. It does not mean $0.
- `pod_leverage` on a position is pod's figure for that position alone (value ÷ margin). `real_leverage` in the overview is the whole account's: all positions' value ÷ account value.
- `funding_owed_usd`: positive means the account owes funding on that position; negative means it is owed. Pod keeps no funding history, so funding on closed positions is not visible.
- `realized_pnl_usd` in `results` adds up the profit or loss pod recorded on each trade in the window. `lifetime` totals come from pod directly.

## What to tell the user

Answer the question asked, in a few lines or a small table. Quote amounts to a sensible precision (cents for large amounts, more decimals for tiny ones); keep the sign. Name the account when it is not the connected wallet. Do not paste the JSON.

## When it fails

`"ok": false` comes with `error` and `fix`; pass them on in plain words. "Pod answered … with an error (503: clob indexer unavailable)" means pod's history service is down: trades, activity and results cannot be read until it is back, while overview, positions and orders usually still work.
