# Pod plugin: scope and sections

*Draft 2, 2026-11-26. Replaces the trader-view draft in [archive/01-feature-ideation-trader-view.md](file:///Users/sabpap/Workspace/Clients/Laurium/pod-ai/specs/archive/01-feature-ideation-trader-view.md).*

## What the plugin is

The plugin gives an AI everything it needs to **read anything and do anything on pod network through pod's own API**. The user can be a human working through an AI assistant, or an agent working alone.

The plugin is a **manual plus an action space**:

- **Skills are the manual.** Each skill tells the AI which request to make for a given goal: the interface (REST, WebSocket or JSON-RPC), the address, the parameters, the units, how to page, how to read the answer, and what goes wrong.
- **Pod's API is the action space.** The prototype makes plain API calls. A CLI may wrap the same calls later.

## What the plugin is not

The plugin does not trade, advise, pick strategies, size positions or set risk limits. How good the AI or its harness is, and what strategy it follows, is the user's business. The plugin's job ends at "the AI knows the right call, makes it correctly, and understands the answer".

## Principles

1. **Pod's API only.** Every fact comes from a pod request. Anything pod does not serve is either left out or listed as a gap.
2. **Right interface for each job.** REST for snapshots and history. WebSocket for live updates. JSON-RPC for sending signed transactions, checking their status and Ethereum-style reads.
3. **Every possible action is covered.** If pod allows it through its public interface, a skill explains it.
4. **The mechanics are part of the manual.** Number scaling, time units, deadlines, nonces and paging are not trading expertise, but every call fails without them. The skills explain them precisely.
5. **Wallet-neutral.** Skills describe what must be signed and by which kind of key, never a specific wallet. The dev wallet is the first signer behind that description.
6. **Accepted is not done.** Every write skill ends with how to check the real outcome.

## One open point before we start: signing

Reads are plain HTTP and WebSocket calls. **Writes cannot be done with plain calls alone.** Every order, cancel, withdrawal or transfer is a transaction that must be encoded and signed by a key before it is sent with `eth_sendRawTransaction`. The send is a plain JSON-RPC call; the encoding and signing need a tool.

For the prototype, the dev wallet already signs with Foundry's `cast` (see [exotic-ai dev wallets](file:///Users/sabpap/Workspace/Clients/Laurium/exotic-ai/docs/dev-wallets.md)). So the skills would describe the call, the signer step would be "ask the wallet to sign this", and the dev wallet answers with `cast`. This is section 3.

---

## The sections

Nine sections. Each one would become a skill (or a part of one) and owns a subset of pod's API.

### 0. Foundations

The shared reference every other skill points to. No actions of its own.

- Network addresses: REST base, JSON-RPC, WebSocket, chain id `129302`.
- Identifiers: account address, market (orderbook) id, transaction hash.
- Numbers: amounts and prices scaled by 10^18, sometimes hex, sometimes decimal strings.
- Times: microseconds almost everywhere, seconds in a few query parameters.
- The `timestamp` freshness parameter and `solution_now`.
- The six paging styles.
- Error codes and what each means.
- The auction cycle: an action is final in about 150 ms, then carried out in the next 500 ms batch.
- Network state: `pod_status` (`read_only`, `paused`), `pod_getPrecompiles`, `pod_getPrecompileInfo`.

### 1. Market data

Read what is traded and at what price. No key needed.

| Goal | Call | Interface |
|---|---|---|
| List every market and its rules (type, status, leverage, fees, price step, size step, minimum order value) | `GET /v1/clob/markets` | REST |
| Live numbers per market (last price, mark, oracle, 24h change, volume, funding, open interest) | `GET /v1/clob/markets/stats` | REST |
| Order book | `GET /v1/clob/orderbook/{id}` | REST |
| Price history bars | `GET /v1/clob/candles/{id}` | REST |
| Per-round results (mark, oracle, funding, open interest, volume) | `GET /v1/clob/solutions` | REST |
| Current round time | `GET /v1/clob/status` | REST |

Open point: whether finding a market by a loose name ("nvidia") belongs in the skill as an instruction ("list markets, then match on name").

### 2. Live updates

How to watch anything as it happens. The plugin explains how to subscribe and stay in sync; what to watch for and what to do about it is the user's choice.

| Goal | Channel |
|---|---|
| Market stats and status changes | `pod_markets` |
| Order book | `pod_orderbook` |
| Forming price bar | `pod_candles` |
| Orders of one or more accounts | `pod_orders_v2` |
| An account's full activity | `pod_activity` |
| An account's positions | `pod_positions` |
| An account's stop and target triggers | `pod_triggers` |
| Withdrawals | `pod_withdrawals` |
| Transfers (no REST route exists) | `pod_transfers` |
| Transaction receipts | `pod_receipts` |
| Every new round | `newHeads` |

Mechanics the skill must teach: `eth_subscribe` and `eth_unsubscribe`; read REST first, then subscribe with `since = solution_now` so nothing is missed; the 2.3-hour replay limit; resuming after the server closes a stream (`resume_since`).

Open point: a one-off agent call cannot hold a WebSocket open. The user's harness needs a way to keep a listener running. We should decide whether the plugin ships a small listener script or only the manual.

### 3. Wallet and identity

Who the AI acts as, and what it is allowed to do.

- **The wallet contract**: the questions every wallet must answer. What is the address? What kind of key is it (main key, bot key, read-only address)? Can it sign a transaction? Can it sign a permission slip (EIP-712)? Until when is it valid?
- **What each kind of key can do**:

  | Action | Main key | Bot key | Read-only |
  |---|---|---|---|
  | Read anything | Yes | Yes | Yes |
  | Orders, triggers, batches | Yes | Yes, gas-free | No |
  | Transfer, withdraw, recover | Yes | No | No |
  | Sign a bot key's permission | Yes | No | No |

- **The first implementation**: the dev wallet.
- **Later implementations**: browser wallets, hardware wallets, email-login wallets. Out of scope for the prototype, but the contract must allow them.

### 4. Account state

Everything about one account. Works for any address with no key, so it covers both "my account" and "someone else's account".

| Goal | Call | Interface |
|---|---|---|
| Cash and spot tokens | `GET /v1/clob/balances/{account}` | REST |
| Positions and account totals (value, cash, withdrawable, profit, leverage) | `GET /v1/clob/positions/{account}` | REST |
| Orders, by status or market | `GET /v1/clob/orders/{account}` | REST |
| Trades | `GET /v1/clob/fills/{account}` | REST |
| Armed stops and targets | `GET /v1/clob/triggers/{account}` | REST |
| Full activity feed (orders, fills, deposits, withdrawals, transfers, forced closes) | `GET /v1/clob/activity/{account}` | REST |
| Forced closes into the backstop | `GET /v1/clob/backstop-transfers/{account}` | REST |
| Gas balance | `eth_getBalance` | JSON-RPC |
| Withdrawable amount of one token | `eth_call` → `withdrawableBalance` | JSON-RPC |

Open point: pod serves the liquidation price and totals, but not an order preview ("what would this order cost in margin, and where would I be liquidated after it?"). Pod's TS SDK computes it locally. We should decide whether a formula in the skill counts as "API only".

### 5. Trading

Every trading action pod allows. All are signed transactions to the orderbook contract (`0x50d0…0002`), sent through JSON-RPC.

| Action | Contract function |
|---|---|
| Place a limit or market order, with optional maker-only, immediate-or-cancel or reduce-only flags | `submitOrder` |
| Edit an order | `update` |
| Cancel an order | `cancel` |
| Place, edit, cancel a stop-loss or take-profit | `submitTrigger`, `updateTrigger`, `cancelTrigger` |
| Up to 64 actions in one go (for example entry plus stop plus target) | `submitBatch` |

The manual for every write:

1. Read the market's rules (section 1) and round price and size to its steps.
2. Scale numbers by 10^18.
3. Set the deadline on the 500 ms grid, in microseconds.
4. Get a free nonce (`GET /v1/accounts/{account}/nonce-slots`).
5. Encode the call (function list from `pod_getPrecompileInfo`).
6. Have the wallet sign it (section 3); wrap it in `delegated(...)` for a bot key.
7. Send it: `eth_sendRawTransaction`, or `pod_sendRawTransaction` to wait for validator feedback.
8. Check it was accepted: `pod_getTxStatus` or `eth_getTransactionReceipt`.
9. Check the real outcome: `GET /v1/clob/orders/{account}` and `/fills`, or `pod_orders_v2`.

### 6. Bot keys (delegation)

Letting a second key trade for an account.

- Create a bot key.
- The main key signs the permission slip (EIP-712): "this key may trade for me until time T".
- Wrap each trade in `delegated(...)` with the slip attached.
- Renew before expiry. A slip cannot be revoked early or limited; the skill must say so.

### 7. Moving money

| Action | How | Interface |
|---|---|---|
| Read bridge rules (tokens, minimum, maximum, other chain) | `GET /v1/bridge/config` | REST |
| Withdraw to the other chain (main key only) | `withdraw` on the bridge contract (`0x50d0…0001`) | JSON-RPC (signed) |
| Track a withdrawal and get its claim proof | `GET /v1/bridge/withdrawals/by-id/{tx}`, `/v2/bridge/withdrawals/{account}` | REST |
| Transfer to another pod account (main key only) | `transfer` on the orderbook contract | JSON-RPC (signed) |
| Test money on testnet | `mint` (undocumented) | JSON-RPC (signed) |
| Deposit from the other chain | A contract call **on the other chain** | Not pod's API |

Open point: deposits and claims happen on the other chain (Arbitrum). They break the "pod API only" rule. Options: leave them to the human, or allow this one exception.

### 8. Transactions and recovery

| Goal | Call | Interface |
|---|---|---|
| Status of a sent transaction | `pod_getTxStatus` | JSON-RPC |
| Receipt | `eth_getTransactionReceipt` | JSON-RPC |
| One transaction, decoded | `GET /v1/tx/{hash}` | REST |
| Recent network transactions (last 1,000) | `GET /v1/transactions` | REST |
| Is the account stuck or locked? | `pod_getAccountDiagnostics` | JSON-RPC |
| Free nonces | `GET /v1/accounts/{account}/nonce-slots` | REST |
| Unlock a frozen account (main key only) | `recover` | JSON-RPC (signed) |

Known problem: `pod_getRecoveryTargetTx`, which recovery needs, returns "Method not found" on staging.

---

## Left out of the API subset

| Calls | Why |
|---|---|
| All `ob_` methods | Deprecated; each has a REST replacement |
| `pod_getVoteBatches`, `pod_getVotes`, `pod_getCommittee`, `pod_getValidatorStatus`, `pod_getSolverState`, `pod_getProcessedDeposits` | Validator and network diagnostics, not needed to trade |
| `pod_listTransactions`, `pod_getTransactions` | Timed out or duplicated by REST |
| `eth_getBlockByNumber`, `eth_getBlockByHash`, `eth_blockNumber`, `eth_getLogs` | Low-level; REST covers the same data more simply |
| `createMarket`, `disableMarket`, `settleMarket` | Pod admins only |
| Multisig contract | Undocumented |

## How we go through this

One section at a time, in order 0 to 8. For each section we decide: which calls are in, what the skill must say about each, and the answers to its open points.

## Open points, collected

| Section | Question |
|---|---|
| 1 | Is "find a market by a loose name" part of the manual? |
| 2 | Does the plugin ship a listener script, or only the manual for subscribing? |
| 3 | Is signing with `cast` acceptable for the prototype's dev wallet? |
| 4 | Does an order-preview formula count as "API only"? |
| 7 | Are deposits and claims on the other chain in or out? |
| 8 | How do we cover recovery while `pod_getRecoveryTargetTx` is missing? |
| All | How many skills: one per section, or fewer, larger ones? |
