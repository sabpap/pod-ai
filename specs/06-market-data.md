# Section 5: Market data

*Spec, 2026-11-26. Decided in the interview of 2026-11-26. Part of [01-plugin-design.md](file:///Users/sabpap/Workspace/Clients/Laurium/pod-ai/specs/01-plugin-design.md).*

Market data answers **"what is traded on pod, at what price, how deep is the book, and how did prices move?"** It only reads; no wallet is needed.

## Decisions

| # | Topic | Decision |
|---|---|---|
| M1 | The headline price | **The mark price on perps, the last traded price on spot** (spot has no mark). Last traded, mark and oracle are always shown beside it, and the answer says which one leads. Trading starts market orders from the same price |
| M2 | Cost of a size | **Yes, when a size is given**: `book MARKET --size N` says what a market order of that size would clear at now, its value and fee, how far from the mid, whether the book is deep enough, and whether it lies inside the default market-order band |
| M3 | Computed numbers | **All four**: spread and mid; funding as % per window and per year, with who pays whom; the mark-vs-oracle gap; a summary over price bars (change, high, low, volume, value). Marked as computed, like Account (A2) |
| M4 | How data is read | A script, `markets.sh`, like `account.sh`: plain numbers, market names, paging handled, `--raw` for pod's answers unchanged |
| M5 | Company information | **Not included.** Descriptions and real-exchange hours live in exotic's own backend, not in pod's API |

## Usage

```
markets.sh [VIEW] [MARKET | QUERY] [options]
```

| View | Answers | Pod calls | Options |
|---|---|---|---|
| `list [QUERY]` (default) | "What can I trade?", "is there a Hynix market?" | `/clob/markets`, `/clob/markets/stats` | `--type perp\|spot`, `--sort volume\|change\|name\|open-interest\|funding`, `--all` (also disabled markets), `--limit` (default 100) |
| `movers` | "Top movers" | Same | `--limit` per group (default 5): rising, falling, most traded |
| `market NAME` | "What's NVDA's price?", "how is NVDA doing?" | Same, plus `/clob/orderbook/{id}?depth=1` | |
| `book NAME` | "NVDA order book", "what would 10 NVDA cost?" | `/clob/orderbook/{id}` (plus stats with `--size`) | `--depth` (default 10), `--size N`, `--side buy\|sell` |
| `bars NAME` | "Hourly bars", "daily gold" | `/clob/candles/{id}` | `--resolution` (1m to 1M, default 1h), `--limit` (1 to 1000, default 50), `--since` |
| `rounds NAME` | "Funding history", "mark vs oracle over time" | `/clob/solutions?orderbook={id}` | `--limit` (1 to 1000, default 20), `--since` |

Market names are resolved by the same rule as Trading: ticker, name or id; perps win unless spot is asked for.

## The cost of a size (M2)

Pod clears each market **once per round at one price for everyone** (checked: every fill of one market in one round has the round's clearing price). So the estimate is not an average across book levels: it is the price of the last level the size needs, the highest ask for a buy and the lowest bid for a sell. The answer says that orders arriving in the same round can move it.

| Field | Meaning |
|---|---|
| `clears_at_about` | The price where the resting orders first cover the size |
| `value_usd`, `fee_usd` | Size × that price; the taker fee on it |
| `vs_mid_pct` | Distance from the mid price |
| `enough_depth`, `fills_size` | Whether the book holds the whole size; if not, how much it holds |
| `within_default_band` | Whether that price lies inside the `market_band_pct` band from the headline price, so a plain market order would fill |

## Facts found while specifying (live, 2026-11-26)

- 62 markets: 54 active perps, 6 active spot, 2 disabled. Perps carry mark, oracle, funding and open interest; spot carries only last price and 24-hour numbers.
- `price_change_24h` is in **basis points** (534 = +5.34%); `open_interest` and `volume_24h` are **USD**; `internal: true` means every oracle source is stale and pod derives the oracle from its book. All from pod's [REST description](https://github.com/podnetwork/pod-sdk/blob/main/doc/api-reference/rest/openapi.yaml).
- On 2026-11-26 (US Thanksgiving, exchanges closed) NVDA's oracle was stale and derived from the book.
- The funding rate applies per `funding_window_us` (8 hours); 0.01% per 8 hours is 10.95% a year.
- Candles: `limit=N` returns N − 1 bars when the page reaches the present (the forming bar is dropped after the limit). The script asks for one more.
- Rounds are half a second apart, so their times need milliseconds (`us_time_ms` in `pod.jq`).
- A market that has never cleared has no book: `/clob/orderbook/{id}` answers 404 "no orderbook snapshot yet". The market view shows it without a book; the book view says it has never traded.
- Pod sends 0 for a price it does not have (the halted ANTHROPIC perp's mark is 0). It counts as no price, so the headline falls back to the last traded price.

## Implementation notes (2026-11-26)

Built in [plugins/pod](file:///Users/sabpap/Workspace/Clients/Laurium/pod-ai/plugins/pod/): `scripts/markets.sh`, `fetch_to` moved into `lib.sh` (shared with `account.sh`), `us_time_ms` in `pod.jq`, and the `/pod:markets` skill (since 0.6.0, `references/markets.md` of the main skill, `/pod:use`). Version 0.5.0.

An independent review found the never-cleared market failing the whole market view and a zero mark shown as the headline price; both fixed before the first commit.

Tested: 13 read-only smoke checks against staging; by hand, every view and option, 700 one-minute bars across two pages with no repeats, 450 rounds across three pages with no repeats, and every refusal.

## Not part of Market data

Following prices as they change (Live), account holdings (Account), placing orders (Trading), company information (M5).
