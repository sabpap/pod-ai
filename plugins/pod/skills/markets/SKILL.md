---
name: markets
description: Read pod network's markets - what is traded, current prices (mark, last traded, oracle), 24-hour change, high, low and volume, funding, open interest, the order book and spread, what a market order of a given size would clear at, price bars (1 minute to 1 month) and per-round history. Use when the user asks what can be traded on pod, the price of something, how a market is doing, top movers, the order book or spread, the cost of buying or selling an amount now, price history or charts data, or funding rates.
argument-hint: "[list [QUERY] | movers | market NAME | book NAME [--size N] | bars NAME [--resolution 1h] | rounds NAME]"
---

# Markets on pod

One script answers every market question. It only reads; no wallet is needed.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/markets.sh" VIEW [MARKET] [options]
```

| The user asks | Run |
|---|---|
| "What can I trade?" / "list the markets" | `markets.sh` (every active market, most traded first) |
| "Is there a Hynix market?" / "find gold" | `markets.sh list hynix` (QUERY matches ticker and name) |
| "Only perps" / "sorted by funding" | `markets.sh list --type perp --sort funding` (sorts: volume, change, name, open-interest, funding) |
| "Top movers" / "what's moving?" | `markets.sh movers` (biggest rises, falls and the most traded; `--limit 3`) |
| "What's NVDA's price?" / "how is NVDA doing?" | `markets.sh market NVDA` |
| "NVDA order book" / "what's the spread?" | `markets.sh book NVDA` (`--depth 20` for more levels) |
| "What would buying 10 NVDA cost right now?" | `markets.sh book NVDA --size 10 --side buy` |
| "Hourly bars for the last day" / "daily gold bars" | `markets.sh bars NVDA --resolution 1h --since 24h` / `markets.sh bars gold --resolution 1d` |
| "Funding history" / "mark vs oracle over the last minutes" | `markets.sh rounds NVDA --limit 200` |

Markets are named loosely: `NVDA`, `nvidia`, `NVDA perp`, `NVDA spot`, or the 0x market id. A name with both a perp and a spot market means the perp; add `spot` or `--spot` for the other. `--raw` returns pod's answers unchanged.

## Which price

| Field | What it is |
|---|---|
| `price` | **The headline price: the mark price on perps, the last traded price on spot.** Quote this one, and say which it is (`price_kind`). Trading starts market orders from the same price |
| `mark_price` | Perps only. What positions are valued and liquidated at. Pod smooths it against the oracle |
| `last_price` | The price the latest auction round cleared at |
| `oracle_price` | Perps only. The outside reference price, e.g. the real NVDA stock |
| `oracle_stale: true` | Every outside source is stale (for a stock, usually because its exchange is closed), so pod derives the oracle from its own book. Say so when quoting the price |

## The market view

`summary` is one line to give the user, e.g. `NVDA perp $150.08 (mark) · +5.32% in 24 h · oracle stale: derived from the book · funding 0.01% per 8 h, longs pay shorts · spread $0.6 (0.4%)`. The fields behind it are `change_24h_pct`, `high_24h`, `low_24h`, `volume_24h_usd` (USD traded), `funding` (`rate_pct` per `every_hours`, `per_year_pct`, `who_pays`), `open_interest_usd`, `mark_vs_oracle_pct`, `book` (best bid and ask, mid, spread) and `rules` (fees, price step, size step, minimum order value, maximum leverage, initial margin, halt time).

## The book and the cost of a size

`bids` and `asks` are best first, each level with its `size` and running `total_size` and `total_value_usd`. With `--size N`, `estimate` says, per side:

- `clears_at_about`: **pod clears each market once per round at one price for everyone**, so a market order of that size would clear at about the price where the resting orders first cover it, not at an average across levels. Orders arriving in the same round can move it.
- `value_usd`, `fee_usd` (taker fee), `vs_mid_pct`.
- `enough_depth: false` with `fills_size` when the book holds less than the size.
- `within_default_band`: whether that price lies inside the market-order band from `/pod:settings`, so a plain market order would fill.

## Bars and rounds

`bars` returns closed bars newest first (the bar still forming is not included; `/pod:live bars` builds it) and a `summary` over them: change, high, low, volume and USD value. `rounds` is pod's per-round record (two rounds a second): traded price, mark, oracle, volume, funding rate and open interest.

## Reading the answer

Every answer has `ok`, `view`, `as_of` and `data`. Lists add `count` and `more` (true when more exists beyond `--limit`). `computed` names the fields the plugin worked out rather than read from pod: spread, mid, mark-vs-oracle gap, funding per year, running book totals, the size estimate and the bar summary. Amounts are exact decimal strings in USD or units of the asset; percentages are already in percent.

`"ok": false` comes with `error` and usually `fix`: pass them on in plain words.

## Not here

Company information (descriptions, real-exchange hours) is not in pod's API. Account holdings are `/pod:account`; continuous updates are `/pod:live`; placing orders is `/pod:trade`.
