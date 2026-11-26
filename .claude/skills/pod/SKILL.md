---
name: pod
description: Work on pod network (the pod staging testnet, chain id 129302) through its REST, JSON-RPC and WebSocket APIs - read any account's balance, account value, positions, profit or loss, margin, liquidation price, open and past orders, trades, fees, stop-loss and take-profit triggers and activity; read markets, prices (mark, last traded, oracle), 24-hour change, funding, the order book, spread, price bars and per-round history; watch, monitor or stream prices, books, orders and positions live; and trade with a wallet - buy, sell, go long or short, limit or market orders, change or cancel orders, cancel all, close a position, set, move or remove a stop-loss or take-profit. Use whenever the user mentions pod, pod network or podtestnet, or asks about their balance, positions, orders, trades, markets, prices or order book on pod, asks to watch something on pod, or asks to buy, sell, cancel or protect a position there.
---

# pod network: the manual

Pod is a trading network of perpetual futures ("perps") and spot markets, matched in auctions twice a second. This skill is a manual: it tells you which of pod's own routes to call for each request and how to read the answers. You make the calls yourself with `curl` and get pod's JSON unchanged. Two small scripts cover the two steps that are easiest to get wrong: converting pod's numbers, and signing and sending a transaction.

## Fixed rules

1. **Pod staging only.** REST `https://staging-rpc.podtestnet.dev/v1`, JSON-RPC `https://staging-rpc.podtestnet.dev`, WebSocket `wss://staging-rpc.podtestnet.dev`, chain id `129302`. Never send anywhere else.
2. **Amounts and prices are integers scaled by 10^18**, in hex or decimal strings, often past 64 bits. Never convert them with floating point or jq arithmetic: use `pod-number.sh`.
3. **Times are microseconds**, with a few exceptions in seconds (candles `from`/`to`, orders `until`, block timestamps).
4. **0 often means none**: a liquidation price of `0x0` is "no liquidation price", not $0.
5. **A size is in units of the asset, not dollars.** When the user names money, work the size out from the price.
6. **Accepted is not filled.** A transaction pod accepts only trades in a later auction round. Report the real outcome after reading the order's status.
7. **Before acting with a wallet, check one is available** with `pod-send.sh --check`. If none is, ask the user to provide one. Never ask for, paste, print or store a private key or password.
8. **Before sending anything that trades, show the user what will be sent and ask.**

## Which reference to read

Read [references/basics.md](references/basics.md) first in every session that touches pod. Then:

| The request | Read |
|---|---|
| Balance, account value, positions, profit or loss, margin, liquidation, orders, trades, fees, triggers, activity, "was I liquidated?", any other address | [references/account.md](references/account.md) |
| What can be traded, a price, "how is X doing", top movers, funding, the order book, spread, the cost of a size, price bars, per-round history, network activity | [references/markets.md](references/markets.md) |
| Buy, sell, long, short, limit or market order, change or cancel an order, cancel all, close a position, stop-loss, take-profit, sizing by money | [references/trading.md](references/trading.md) |
| Watch, monitor, stream, "tell me when", a live page or dashboard | [references/live.md](references/live.md) |

Each reference names pod's routes, their parameters, the fields of the answer and the traps. For anything they do not cover, use the links to pod's own API docs at the end of basics.md.

## The two scripts

Both are in this skill's `scripts/` folder; run them by their full path (the references write them as plain `pod-number.sh` and `pod-send.sh`). Each has `--help`.

| Script | Use |
|---|---|
| `scripts/pod-number.sh` | Exact conversion: `from-pod 0x82ff658cf0b3f0000` → `151.03`, `to-pod 151.03` → `151030000000000000000`, `time 1795710282500000` → `2026-11-26T16:24:42.500Z`, `us now` → microseconds, `int 0x32` → `50` |
| `scripts/pod-send.sh` | `--check`: is a wallet available and does pod staging answer. Otherwise signs and sends **one** transaction you built from [trading.md](references/trading.md): `pod-send.sh [--dry-run] 'SIGNATURE' ARGS…`. It answers with the transaction hash and pod's `pod_getTxStatus` result. `--dry-run` signs and shows it without sending |

`pod-send.sh` finds the wallet in `POD_PRIVATE_KEY` (a private key in the environment) or `POD_KEYSTORE` / `--keystore NAME` (a Foundry keystore whose password is in the macOS Keychain). It refuses any network but pod staging.

## Answering

Answer the question in a few plain lines or a small table, with amounts converted exactly and rounded only for display. Say which price you quote (mark, last traded or oracle), name the account when it is not the user's own, and say when a number is worked out rather than read from pod. Do not paste raw JSON unless asked.
