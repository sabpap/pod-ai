---
name: status
description: Check whether the pod plugin can act on pod network right now, and what the agent can and cannot do there. Use when the user asks if pod is connected, working or ready, which wallet is in use, whether the agent can trade, or why something on pod failed; and before acting on pod when the current state is unknown.
argument-hint: "[--quick]"
---

# Status: can the AI act on pod right now?

Run:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/status.sh"            # full check: also signs a test message (about 2 s)
"${CLAUDE_PLUGIN_ROOT}/scripts/status.sh" --quick    # without signing (under 1 s)
```

Use the full check when the user asks. Use `--quick` when another pod skill only needs the facts. Status never sends a transaction.

## The levels

`level` is one of five. The first that applies wins:

| Level | Meaning | Can trade? |
|---|---|---|
| `not set up` | No wallet is connected | No. Point to `/pod:setup` |
| `problem` | Something is broken: see `problems` | No |
| `connected, read-only` | Pod is paused, or the account has no cash: see `warnings` | No |
| `connected, untested` | Works, but no test transaction has passed and no real send has been accepted | Yes, with a warning |
| `ready to trade` | Works, and sending is proven | Yes |

## What to tell the user

1. **The `summary` line**, as given. For example: `pod: ready to trade · 0x035A…Da70 · value $99.9967 · 1 position · 0 orders · asks before trading`. "Value" is the account value: cash plus the unrealized profit or loss of open positions. It is the answer to "how much do I have". Cash alone is not: opening a perp only holds part of the cash as collateral, so cash barely moves.
2. **Each entry in `problems`**: the `error`, then its `fix`, in plain words.
3. **Each entry in `warnings`.**
4. **The trading settings**, from `settings.in_words`, e.g. "asks before every trade · market orders within 2% of the price · limit orders rest 1 day". They are changed with `/pod:settings`.
5. **Capabilities**, only when the user asks what the agent can do, or when trading is not possible: list `capabilities` as can / cannot, with `why` for each "cannot".

Keep it to a few lines. Do not dump the JSON.

## Reading the rest

| Field | Meaning |
|---|---|
| `check` | `full` or `quick` |
| `network.writes_open` | False when pod is paused or read-only: reading still works, sending does not |
| `wallet.present` | The keystore and its Keychain entry exist, or the variable is set |
| `wallet.signs` | `true` or `false` after a full check; `null` after a quick one |
| `account` | Account value (cash plus unrealized profit or loss), cash, unrealized profit or loss and withdrawable cash, in USD; open positions and orders; `frozen`. Status does not list each position, its margin or its liquidation price |
| `proof.test_transaction` | The last test transaction from setup: `passed` or `failed`, with its time |
| `proof.last_send` | The latest real send through the plugin: accepted (`ok: true`), or refused with `lasting: true` (region block, blacklist, frozen account) or `lasting: false` (passing errors such as a timeout) |
| `settings` | `approval` (ask or auto), `market_band_pct`, `default_ttl`, and `in_words`; defaults filled in |

A refusal with `lasting: true` puts the level at `problem` until a later send is accepted or a test passes. A passing refusal changes nothing.

## What the plugin does not do

Deposits, withdrawals, transfers between accounts, bot keys and recovering a frozen account are not part of this plugin. Say so plainly if the user asks for them.
