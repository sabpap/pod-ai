# Live: following pod as it changes

Pod pushes updates over a WebSocket after each auction round. This reference covers the protocol and how to run a listener from an agent. Numbers follow [basics.md](basics.md).

## Contents

- [The one rule people miss: subscribe with `since`](#the-one-rule-people-miss-subscribe-with-since)
- [Subscribing](#subscribing)
- [Channels](#channels)
- [Catching up without gaps](#catching-up-without-gaps)
- [Repeats on state channels](#repeats-on-state-channels)
- [When the connection drops](#when-the-connection-drops)
- [When pod closes a stream](#when-pod-closes-a-stream)
- [Reading `pod_orders_v2`](#reading-pod_orders_v2)
- [Running a listener from an agent](#running-a-listener-from-an-agent)

## The one rule people miss: subscribe with `since`

Without `since`, the state channels (`pod_markets`, `pod_positions`, `pod_triggers`) send **nothing until something changes**. On a quiet account a positions view stays empty for hours while the subscription looks healthy: "subscribed", no error. Checked on staging: `pod_positions` with `since` sent the current state at once; without it, nothing.

So, for any live view:

1. Read the matching REST route and show the current state from it: `/v1/clob/positions/{a}`, `/v1/clob/triggers/{a}`, `/v1/clob/markets/stats`, `/v1/clob/orderbook/{id}`, `/v1/clob/activity/{a}`.
2. Take that answer's round time: `timestamp` on positions, balances, triggers and the order book; `solution_now` on the others. `GET /v1/clob/status` also gives `solution_now`.
3. Subscribe with `since` set to it, **as a JSON number**. A string is refused (`-32602`, `expected u64`).

## Subscribing

Connect to `wss://staging-rpc.podtestnet.dev` and send:

```json
{"jsonrpc":"2.0","id":1,"method":"eth_subscribe","params":["pod_positions",{"account":"0x035a…","since":1795716449000000}]}
```

The answer to `id` 1 is the subscription id (or an `error`). Updates then arrive as notifications, one per round that touches what you follow:

```json
{"jsonrpc":"2.0","method":"eth_subscription","params":{"subscription":"0x…","result":{ … }}}
```

`eth_unsubscribe` with the subscription id ends it. One connection can carry several subscriptions.

## Channels

| Channel | Kind | Options | Each update |
|---|---|---|---|
| `pod_markets` | state | `orderbook_ids` (omit for all), `since` | One market's stats, the same fields as `/clob/markets/stats` plus `status`. Sent for each round in which the market cleared (NVDA: about every round) |
| `pod_orderbook` | delta | `orderbook_ids`, `depth` (≥ 1), `since` | The book after the round, the shape of `/clob/orderbook/{id}` |
| `pod_candles` | delta | `orderbook_ids`, `since` | `{orderbook, timestamp_us, price, volume}`: the round's clearing price and volume (decimal strings). **Not a bar**: fold rounds into the bar yourself (first price = open, highest = high, …) |
| `pod_orders_v2` | delta | `bidder` (one account) or `bidders` (up to 64), `orderbook_ids`, `since`, `since_book` | Order events of one market in one round; see [below](#reading-pod_orders_v2) |
| `pod_activity` | delta | `account` (required), `since` | `{"<round µs>": [entries]}`, the entries of `/clob/activity/{a}` |
| `pod_positions` | state | `account` (required), `since` | `{account, data}`; `data` is `/clob/positions/{a}` with its `timestamp` |
| `pod_triggers` | state | `account` (required), `since` | The `/clob/triggers/{a}` fields (up to 200 triggers) plus `account` |
| `pod_receipts` | delta | `account` and/or `tx_hashes` (up to 256), `since` | `{timestamp_us, receipts: [{tx_hash, status}]}`. `status: false` means executed and failed; the nonce is used either way |
| `newHeads` | blocks | none | Each new block (round number `number`, hex; `timestamp`, hex seconds) |

Pod also has `pod_orders` (older form of `pod_orders_v2`), `pod_withdrawals` and `pod_transfers`; see pod's [JSON-RPC description](https://github.com/podnetwork/pod-sdk/blob/main/doc/api-reference/json-rpc/openapi.yaml) under `eth_subscribe`.

## Catching up without gaps

`since` is a round time in microseconds.

- **State channels** (`pod_markets`, `pod_positions`, `pod_triggers`): `since` is the oldest state you accept. The node waits until it has reached it (up to 2 s), sends one current snapshot, then streams. If it cannot reach it in time: error `995` with its current time in `data`; wait a second and subscribe again.
- **Delta channels** (`pod_orderbook`, `pod_candles`, `pod_activity`, `pod_orders_v2`, `pod_receipts`): pod first replays every round after `since`, then streams. Read REST, subscribe from its round time, and nothing in between is lost.
- **Pod keeps about 2.3 hours** of rounds for replay. Checked on staging: a `since` 2 hours old was replayed; 3 hours old was refused with `-32602 since too old; backfill via REST then resubscribe`. Then read what you missed from REST and subscribe from a recent round.
- `pod_receipts` catch-up is capped at 10,000 receipts; past that the stream closes with `-32026` and `resume_since`.

## Repeats on state channels

A state channel can send the same round twice (the starting snapshot, then that round's live push) or, rarely, an older one late. Keep the newest `timestamp` per market (or per account) and drop anything not newer.

## When the connection drops

Reconnect (wait 1 s, then double up to 30 s) and subscribe again with `since` = the last round you handled. Pod replays what was missed. A connection can also die without closing: send something small (for example `eth_chainId`) every 30 s and reconnect after about 75 s of silence. While a subscription is open and healthy, no updates means nothing happened.

## When pod closes a stream

Pod may end a subscription itself, rather than send a stream with a gap. It arrives as a notification with `error` instead of `result`:

```json
{"jsonrpc":"2.0","method":"eth_subscription","params":{"subscription":"0x…","error":
  {"code":-32020,"message":"subscription lagged behind the tick broadcast","data":{"resumable":true,"resume_since":1718900000000000}}}}
```

Subscribe again with `since` = `data.resume_since` (and `since_book` = `data.resume_since_book` on `pod_orders_v2`). Without `resume_since`, reuse your last `since`. Codes: `-32020` fell behind, `-32021` node shutting down (reconnect), `-32022` too slow to accept, `-32023` a server bug (do not retry in a loop), `-32026` receipt catch-up cut short. A close is the only sign that a delta stream lost data.

## Reading `pod_orders_v2`

One frame is one market (`book`) in one round (`batch`, the round the actions **landed in**, which can be earlier than an order's deadline).

- `orders`: the orders created in this round, each once: `id`, `tx`, `n` (the transaction's nonce), `px` (price), `sz` (signed size: the sign is the side), `end`, and optional `type: "market"`, `kind`, `reduce_only`, `ioc`, `post_only`, `trigger`. A missing optional field has its default (limit order, user-signed, false).
- `events`: what happened, each with `k` and either `o` (an index into `orders`) or `id` (an order from an earlier round). Kinds: `new`, `reject` (`why`), `fill`, `cancel` (`st` when the engine removed it: `post_only_refused`, `self_trade_canceled`, `margin_canceled`), `cancel_reject`, `expire`, `modify`, `modify_reject` (`code`, `why`).
- A `fill` has `b` and `q` (base and quote filled **by this fill**) and `tb`, `tq`, `tf` (the order's running totals). Add `b` and `q`; reading the totals as per-fill amounts counts twice. `f` is this fill's fee. The fill that ends an order carries `st`.
- `accts` (owner addresses) and `a` (an index into it) appear only when the subscription names several accounts. Decode on whether `accts` is present.
- Ignore `k` values and fields you do not know.

To learn when your own order fills, compute its id before sending (see [trading.md](trading.md#4-encode-the-call)) and watch for it here.

## Running a listener from an agent

A listener runs until stopped, so never run it in the foreground without a time limit.

| The user wants | In Claude Code |
|---|---|
| To be told when something happens ("tell me when NVDA drops below 140") | A listener that exits when the condition holds, run with Bash `run_in_background: true`. You are woken once, when it ends |
| A running commentary ("keep me posted for half an hour") | The Monitor tool on the listener's output; each line becomes a message. Print at most one line every 30 s or so: NVDA alone updates twice a second |
| A live page or dashboard | The page connects to pod itself and follows every rule above. Check it shows data within a few seconds before handing it over |
| A stop-loss or take-profit | No listener: a pod trigger watches the price on pod's side ([trading.md](trading.md#recipes)) |

A minimal listener for Node.js 22 or later (built-in WebSocket), to write to a temp file and adapt. It reads the REST state first, subscribes from its round, drops repeats, resumes after a drop, and prints one JSON line per update:

```js
// node listen.mjs CHANNEL 'OPTIONS_JSON' [REST_PATH]
// e.g. node listen.mjs pod_positions '{"account":"0x…"}' /clob/positions/0x…
const [channel, opts, restPath] = [process.argv[2], JSON.parse(process.argv[3] || '{}'), process.argv[4]];
const BASE = 'https://staging-rpc.podtestnet.dev/v1';
const STATE = ['pod_markets', 'pod_positions', 'pod_triggers'];
const first = restPath ? await (await fetch(BASE + restPath)).json() : null;
if (first) console.log(JSON.stringify({ rest: first }));
let since = first?.timestamp ?? first?.solution_now ?? (await (await fetch(BASE + '/clob/status')).json()).solution_now;
const newest = new Map();   // state channels: newest round per market or account
let ws, heard = Date.now(), delay = 1000;
const tsOf = (r) => r.timestamp ?? r.timestamp_us ?? r.batch ?? r.data?.timestamp ?? Number(Object.keys(r)[0]);
function connect() {
  ws = new WebSocket('wss://staging-rpc.podtestnet.dev');
  ws.onopen = () => ws.send(JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_subscribe',
    params: [channel, { ...opts, since: Number(since) }] }));
  ws.onmessage = (ev) => {
    heard = Date.now(); delay = 1000;
    const m = JSON.parse(ev.data);
    if (m.id === 1 && m.error) { console.log(JSON.stringify({ error: m.error })); process.exit(1); }
    if (m.method !== 'eth_subscription') return;
    if (m.params.error) { since = m.params.error.data?.resume_since ?? since; ws.close(); return; }
    const r = m.params.result, ts = Number(tsOf(r)), key = r.orderbook_id ?? 'all';
    if (STATE.includes(channel) && ts <= (newest.get(key) ?? 0)) return;   // a repeat
    newest.set(key, ts); since = Math.max(Number(since), ts);
    console.log(JSON.stringify(r));
  };
  ws.onclose = () => { setTimeout(connect, delay); delay = Math.min(delay * 2, 30000); };
}
setInterval(() => {
  if (Date.now() - heard > 75000) ws.close();
  else if (ws.readyState === 1) ws.send('{"jsonrpc":"2.0","id":2,"method":"eth_chainId","params":[]}');
}, 30000);
connect();
```

It is not for `newHeads`, which takes no options. On a reconnect it resumes from the newest round it printed; on `pod_orders_v2` with several markets, also keep the last `book` and pass it as `since_book`. Add the condition the user asked for (convert numbers exactly before comparing) and `process.exit(0)` when it holds. Tell the user what is running and how to stop it, and stop listeners that are no longer needed.
