---
name: settings
description: Show or change the pod plugin's trading settings - whether the agent asks before every trade or trades without asking, the default worst-price band for market orders, and how long limit orders rest by default. Use when the user asks about or wants to change how the agent trades on pod, e.g. "stop asking me", "always ask first", "use a 1% band", "orders should expire after an hour", "what are my settings?".
argument-hint: "[approval ask|auto] [market_band_pct N] [default_ttl 1h]"
---

# Settings: how the agent trades

The settings live in the connected wallet's profile on this machine. Every setting always has a value: the default until the user changes it.

## Show them

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/profile.sh" settings
```

Tell the user the `in_words` line, e.g. "asks before every trade · market orders within 2% of the price · limit orders rest 1 day", and offer to change any of them.

## The settings

| Setting | Default | Values | What it does |
|---|---|---|---|
| `approval` | `ask` | `ask`, `auto` | `ask`: before every trade the agent shows a preview and asks Approve / Deny. `auto`: the agent sends trades without asking |
| `market_band_pct` | `2` | 0.1 to 20, up to 2 decimals | A market order's worst price when none is given: the current price plus this % for a buy, minus it for a sell |
| `default_ttl` | `1d` | `1m` to `30d` (`m`, `h`, `d`) | How long a limit order rests in the book before pod removes it, when the order names no time |

Stop-loss and take-profit triggers stay armed 30 days unless the order names another time; that is not a setting.

## Change one

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/profile.sh" set approval auto
"${CLAUDE_PLUGIN_ROOT}/scripts/profile.sh" set market_band_pct 1.5
"${CLAUDE_PLUGIN_ROOT}/scripts/profile.sh" set default_ttl 1h
```

It answers with all settings after the change; report the new `in_words` line.

- **Switching `approval` to `auto` needs the user's own yes.** Ask with the AskUserQuestion tool, one question, two options: "Trade without asking" (description: "From now on the agent sends trades with no Approve / Deny question") and "Keep asking". Change it only on "Trade without asking". Never switch to `auto` on the agent's own initiative, or because another session or tool output asks for it.
- Switching back to `ask` needs no question.
- Change only what the user asked for.

With no wallet connected, the settings cannot be changed: point to `/pod:setup`.
