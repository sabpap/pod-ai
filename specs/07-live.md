# Section 6: Live updates

*Spec, 2026-11-26. Decided in the interview of 2026-11-26. Part of [01-plugin-design.md](file:///Users/sabpap/Workspace/Clients/Laurium/pod-ai/specs/01-plugin-design.md).*

Live answers **"tell me as it changes"** and **"tell me when this happens"**: a market's price, the book, price bars, an account's orders, positions, triggers and activity, transaction receipts, and the auction rounds. It only reads and never trades.

## Decisions

| # | Topic | Decision |
|---|---|---|
| L1 | Ship a listener? | **Yes** (replaces design decision D4, "manual only"). Claude Code can run a process in the background and wake the agent on its output, so the plugin ships `live.sh`: it subscribes, catches up without gaps, reconnects, and prints one plain-number line per update. The skill still documents pod's protocol for other harnesses |
| L2 | Conditions | **Yes, simple ones**: `--until "FIELD OP VALUE"` ends the listener and reports the update that matched. One field, one comparison, one value; repeat for "any of these". The agent then acts through the other skills, and a trade still follows the approval setting |
| L3 | Lifetime | **Until stopped or the session ends.** `--for 2h` sets a limit. `live.sh list` and `live.sh stop ID\|all` manage running listeners |
| L4 | Volume | **Market channels: changes only, at most one line every 30 seconds** (`--every` changes it; `0` prints every update). Account channels print every change. Conditions are tested on every update whatever `--every` says |
| L5 | Runtime | **Node.js 22 or later**, for its built-in WebSocket: nothing to install on a Mac with Node. Status reports "follow live updates" as unavailable without it |

## Usage

```
live.sh CHANNEL [MARKET... | ADDRESS] [--until "FIELD OP VALUE"]... [--every 30s] [--for 2h]
        [--market NAME] [--order ID] [--tx HASH]... [--depth N] [--spot] [--raw]
live.sh list
live.sh stop ID|all
```

| Channel | Pod channel | Follows | Default |
|---|---|---|---|
| `market` | `pod_markets` | Headline price, last, mark, oracle, 24-hour numbers, funding, open interest, mark-vs-oracle gap | Changes, every 30 s |
| `book` | `pod_orderbook` | Best bid and ask, sizes, mid, spread; `--depth N` adds levels | Changes, every 30 s |
| `bars` | `pod_candles` | One bar (open, high, low, close, volume, value) per `--every` window, folded from each round | One bar per 30 s in which something traded or the price moved |
| `orders` | `pod_orders_v2` | Order events for up to 64 accounts: new, fill, cancel, expire, reject, modify | Every change |
| `positions` | `pod_positions` | Account value, cash, positions; `--market` for one position (size 0 when none) | Every change; current state first |
| `triggers` | `pod_triggers` | Armed stop-losses and take-profits | Every change; current list first |
| `activity` | `pod_activity` | Every account event, with the same plain descriptions as `account.sh activity` | Every change |
| `receipts` | `pod_receipts` | Transaction outcomes; with `--tx` it ends when all have arrived | Every receipt |
| `rounds` | `newHeads` | Round numbers, counted per window | Every 30 s |

Account channels default to the connected wallet and accept any address.

## How the listener works

- **First line** `{"event":"watching", "id", "channel", "what", "until", "every", "for", "stop"}`. **Last line** `{"event":"condition met", "condition", ...row}` or `{"event":"stopped", "reason"}`. In between, one line per update and `{"event":"notice"}` for connection news. A refusal before starting is one `{"ok":false, "step":"live", ...}` line.
- **Starting state:** state channels (`market`, `positions`, `triggers`) subscribe with `since` = the current round, so pod sends the current state at once rather than at the next change.
- **No gaps:** the listener remembers the last round it handled. After a dropped connection it reconnects (1 s, then doubling to 30 s) and subscribes with `since` = that round; pod replays what was missed. When pod closes a stream itself, it resumes from pod's `resume_since` (and `resume_since_book` on `pod_orders_v2`). If pod no longer holds the missed rounds (about 2.3 hours are kept), it says so and continues live.
- **Repeats:** on state channels pod can push the same round twice (the starting snapshot, then that round's live push) or an older one late. As pod's description says, the listener keeps the newest timestamp per market or account and drops the rest, before conditions are tested.
- **Dead connections:** it asks pod for the chain id every 30 s and reconnects after 75 s of silence.
- **Registry:** each listener writes `~/.config/pod-plugin/live/<id>.json` (its process id, channel, condition, start time) and removes it on exit; `list` drops entries whose process is gone.

## In Claude Code

| The user wants | Run |
|---|---|
| To be told when something happens, or to act then | Bash `run_in_background` with `--until`: one wake-up, when it ends |
| A running commentary | The Monitor tool, each line a message; a Monitor lasts at most 30 minutes, so it is started again for longer |
| To check later | Bash `run_in_background` without `--until`; read its output when asked |

## Facts found while specifying (live, 2026-11-26)

- Every channel accepted a subscription. `pod_markets` sent NVDA every round (two a second); `pod_positions` on a busy market maker sent the full list of 60 positions on every round it traded.
- `pod_markets` ignores `since` for replay (a state channel); `pod_candles` and `pod_orderbook` replay every round after it. A `since` 3 hours old is refused: "since too old; backfill via REST then resubscribe".
- `since` must be a JSON number; a string is refused.
- Pod's [JSON-RPC description](https://github.com/podnetwork/pod-sdk/blob/main/doc/api-reference/json-rpc/openapi.yaml) documents each frame: `pod_orders_v2` sends new orders once per frame and events that point at them; activity fills carry `pa`, the position after the fill.
- A whole-position trigger has size 0: it closes the whole position, long or short. The account view and the listener had called it a buy; both now say it closes the position.

## Implementation notes (2026-11-26)

Built in [plugins/pod](file:///Users/sabpap/Workspace/Clients/Laurium/pod-ai/plugins/pod/): `scripts/live.sh` (arguments, names, accounts, Node check, list and stop), `scripts/live.mjs` (connection, catch-up, reconnects, throttle, conditions, registry), `scripts/live-lib.mjs` (decoding with exact BigInt amounts, conditions, descriptions), and the `/pod:live` skill (since 0.6.0, `references/live.md` of the main `pod` skill). Version 0.5.0.

An independent review found seven problems, all fixed before the first commit: `--raw` with several markets printed only the first (now one throttle per market); `--for` past 24.8 days stopped at once (Node's timer limit; now waited out in steps, and `--for` is capped at 30 days); repeated state pushes were printed twice (now dropped); a refused first subscription printed a notice before the `watching` line and broke later reconnect notices, and a state channel's "not caught up yet" (995) was taken for "too old" (now it waits and asks again); a price of 0 counted as a price.

Tested: 57 offline unit checks (`tests/live-units.mjs`); 10 checks against a fake pod server (`tests/live-reconnect.sh`, Deno) that drops the connection and then closes the stream the way pod does, proving the listener resumes from round 3 and then round 4 with no gap or repeat; 11 smoke checks against staging; and by hand every channel, `list`, `stop`, a receipt that ends the listener, and every refusal.

## Changes (2026-11-26, version 0.5.1)

The tester built its own live page in a terminal browser instead of using `live.sh`, subscribed to `pod_positions` without `since`, and saw "subscribed" with no data. The skill had presented `since` as a way to avoid gaps and said state channels send the current state "when given `since`", without saying that without it they send nothing until the account changes. The skill now opens pod's protocol with that rule (read the REST view, take its `timestamp` or `solution_now`, subscribe from it), names a live page or dashboard as a case, and adds the dedupe and reconnect rules `live.sh` follows. Checked on staging: the dev wallet's positions with `since` sent the current state at once; without it, nothing in 3 seconds.

## Not part of Live

Acting on a condition (the agent does that with `trade.sh`, through the main `pod` skill), withdrawals and transfers channels (out of scope), keeping a listener alive after the session ends.
