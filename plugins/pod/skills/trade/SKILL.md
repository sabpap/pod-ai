---
name: trade
description: Place, change and cancel orders and stop-loss / take-profit triggers on pod network with the connected wallet - buy or sell a market at a limit price or at market, edit or cancel an order, cancel all orders, close all or part of a position, set, move or remove a stop-loss or take-profit. Use when the user asks to buy, sell, short, go long, place, change or cancel an order, close a position, protect a position, or cancel everything on pod.
argument-hint: "buy|sell|close|edit|cancel|cancel-all|stop-loss|take-profit|edit-trigger|cancel-trigger ..."
---

# Trade on pod

Every action goes through four steps: **plan → approve → send → follow**. The script is:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/trade.sh" ACTION ...
```

Only the connected wallet trades, and only on pod staging. If no wallet is connected, point to `/pod:setup`.

## 1. Plan

Turn the request into one action. Nothing is sent at this step.

| The user says | Run |
|---|---|
| "Buy 0.5 NVDA at 150" | `trade.sh buy NVDA 0.5 --price 150` |
| "Sell 0.5 NVDA at market" | `trade.sh sell NVDA 0.5 --market` |
| "Buy at market, but no more than 152" | `trade.sh buy NVDA 0.5 --market --max-price 152` |
| "Short 2 AAPL at 230" | `trade.sh sell AAPL 2 --price 230` (selling a perp you do not hold opens a short) |
| "Buy NVDAx spot" | add `--spot` (or name the market "NVDA spot") |
| "Close my NVDA position" / "close half" | `trade.sh close NVDA` / `trade.sh close NVDA --percent 50` |
| "Move that order to 149" | `trade.sh edit ORDER_ID --price 149` (and/or `--size`: the new total size) |
| "Cancel that order" / "cancel everything" | `trade.sh cancel ORDER_ID` / `trade.sh cancel-all [MARKET]` |
| "Stop-loss at 140" / "take profit at 170" | `trade.sh stop-loss NVDA --trigger-price 140` / `trade.sh take-profit NVDA --trigger-price 170` |
| "Move my stop to 145" / "remove it" | `trade.sh edit-trigger TRIGGER_ID --trigger-price 145` / `trade.sh cancel-trigger TRIGGER_ID` |

Options: `--maker-only` (only rest in the book, never take), `--ioc` (fill what you can now, cancel the rest), `--reduce-only` (perps: only shrink a position), `--rests 1h` (how long a limit order stays, default 1 day), `--band 1.5` (a market order's worst price as a % from the current price, default 2%), `--limit-price` for a trigger (else it trades at market within the band), `--size` for a trigger (else the whole position).

Order ids and trigger ids come from `/pod:account orders` and `/pod:account triggers`. Markets can be named loosely: `NVDA`, `nvidia`, `NVDA perp`, `NVDA spot`.

The plan answer has `plan_id`, `summary`, `preview`, `notes` and `needs_approval`. **Notes** say what was changed: prices and sizes are rounded to the market's steps on the side that never trades worse than asked (a buy price down, a sell price up, a size down), and a market order's worst price is shown. Plans expire after 2 minutes.

## 2. Approve

When `needs_approval` is true (the `approval` setting is `ask`, the default), ask with the AskUserQuestion tool: one question, two options.

- **question:** the `summary` and the preview in one or two plain sentences, e.g. "Approve: buy 0.5 NVDA perp at $150 (rests 1 day)? Value $75, fee up to $0.03, margin $3.75, free margin after $96.2." Add each note.
- **header:** "Approval"
- **options:** "Approve" (description: "Send it now"), "Deny" (description: "Send nothing").

Only "Approve" sends; any other answer is Deny. If AskUserQuestion is not available, ask in plain text and accept only "approve" or "deny". Never send a plan the user has not approved while `approval` is `ask`.

When `needs_approval` is false (`approval` is `auto`), go straight to step 3, or plan and send in one call with `--send`.

## 3. Send

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/trade.sh" send PLAN_ID
```

It sends exactly the approved plan and returns as soon as pod has accepted it. **Tell the user at once**, using `summary` ("Sent: buy 0.5 NVDA perp at $150 · waiting for the next auction round"). Accepted is not traded yet: pod trades at its next auction round.

## 4. Follow, in the background

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/trade.sh" follow PLAN_ID
```

Run it **in the background** (Bash `run_in_background`), so the user can keep talking. When it ends, report its `outcome` in one line: "Filled: … at an average $…, fee $…", "Resting in the book …", "Partly filled …", "Refused: not enough margin …", "Armed: stop-loss …", "Cancelled.". If `final` is false, nothing settled within the timeout: say so and offer to check again. Without background commands, run it as a second step right after sending.

## Settings

| Setting | Default | Change with |
|---|---|---|
| `approval` | `ask` | `profile.sh set approval auto` ("let the agent trade without asking") |
| `market_band_pct` | `2` | `profile.sh set market_band_pct 1.5` |
| `default_ttl` | `1d` | `profile.sh set default_ttl 1h` |

Change a setting only when the user asks.

## When it fails

`"ok": false` comes with `error` and `fix`: pass them on in plain words. Pod's refusals are passed on with pod's own reason. A refusal for a lasting reason (region block, blacklist, frozen account) also makes `/pod:status` report a problem.

## Not part of this plugin

Advice, strategies, risk limits, bracket orders, free-form batches, transfers, withdrawals and bot keys.
