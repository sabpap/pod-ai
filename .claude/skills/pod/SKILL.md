---
name: pod
description: Work on pod network (staging testnet) through its raw API - markets, prices, order books, accounts, balances, positions, orders, trades, live updates, and trading by signed transactions. Use when the user asks anything about pod or pod network, or asks to buy, sell, cancel or watch something on pod.
---

# pod network

pod is a network for markets: spot and perpetual order books, matched in frequent batch auctions. It looks like an Ethereum chain to tools, so JSON-RPC, wallets and Foundry's `cast` work with it.

## Staging, the only network to use

| What | Where |
|---|---|
| Chain id | `129302` |
| JSON-RPC | `https://staging-rpc.podtestnet.dev` |
| REST API (read-only) | `https://staging-rpc.podtestnet.dev/v1` |
| WebSocket channels | `wss://staging-rpc.podtestnet.dev` |
| App and explorer | `https://staging-app.podtestnet.dev` |

Reading needs no wallet. Trading means signing transactions to pod's orderbook contract and sending them through JSON-RPC.

## The docs

Everything else is in pod's docs. Read them for each task and follow them. Every page is also plain Markdown at its URL with `.md`.

- https://docs.v2.pod.network/llms.txt : index of every page, with links.
- https://docs.v2.pod.network/llms-full.txt : every page in one file (about 1 MB); download it once and search it.
- https://docs.v2.pod.network/guides-references/readme.md : getting started and network settings.
- https://docs.v2.pod.network/guides-references/references/rest.md : REST API; its routes are on the Markets, Account and Explorer pages listed in the index.
- https://docs.v2.pod.network/guides-references/references/json-rpc.md : JSON-RPC API.
- https://docs.v2.pod.network/guides-references/references/json-rpc/ethereum-interface-eth.md : `eth_` methods, including the WebSocket subscriptions.
- https://docs.v2.pod.network/guides-references/references/applications-precompiles/orderbook.md : the orderbook contract that trades go to.
- https://docs.v2.pod.network/guides-references/references/json-rpc-errors.md : error codes.
- https://docs.v2.pod.network/guides-references/references/market-configurations.md : market settings.
- https://docs.v2.pod.network/guides-references/guides/place-a-perpetual-order.md : one of the guides; the index lists the others.
- https://docs.v2.pod.network/documentation/markets/markets-overview.md : how pod's markets work.
- https://raw.githubusercontent.com/podnetwork/pod-sdk/main/doc/api-reference/rest/openapi.yaml : REST OpenAPI file.
- https://raw.githubusercontent.com/podnetwork/pod-sdk/main/doc/api-reference/json-rpc/openapi.yaml : JSON-RPC OpenAPI file.
- https://github.com/podnetwork/pod-sdk/tree/main/doc : the source of these docs.

## The wallet

Before anything that needs a wallet, run `scripts/check-wallet.sh` from this skill's folder. It prints the wallet's address and its form: a private key in `POD_PRIVATE_KEY`, or a Foundry keystore named by `POD_KEYSTORE` (folder `~/.foundry/keystores`, or `POD_KEYSTORE_DIR`). A keystore's password is in the macOS Keychain, service `foundry-keystore`, account = the keystore name.

If no wallet is found, ask the user for one. Tell them not to paste a private key into the chat: they set `POD_PRIVATE_KEY` in the shell that starts Claude Code, or name a keystore with `POD_KEYSTORE`.

## Rules

1. Use pod staging only (chain id 129302). Never send anything to another network.
2. Never print, store or commit a private key or a password.
