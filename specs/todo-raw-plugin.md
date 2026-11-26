# To do: a raw version of the plugin, for comparison

*Noted 2026-11-26, while deciding how the Account section reads data (decision: scripts that return plain numbers). Not started.*

## Why

We need to show the difference between two ways an agent can use pod:

1. **Raw API use**: the agent reads pod's docs and calls the API itself.
2. **The plugin product**: skills that break each goal into defined actions, and scripts that call pod and turn its answers into plain, checked results.

A second, deliberately raw plugin makes that difference visible, side by side, on the same tasks.

## What the raw version is

- **One skill**, for example `pod-raw`. No scripts.
- The skill is a manual: pod's REST routes, JSON-RPC methods and WebSocket channels; the parameters; the number formats (10^18 scaling, hex or decimal strings, microseconds); the six paging styles; how to build, sign and send a transaction with `cast`.
- **Full flexibility**: the agent may call any route with any parameter.
- **Raw results**: the agent gets pod's JSON unchanged and converts numbers itself, every time.
- **Not verifiable**: no tested conversion, no profile, no status levels, no send recording. What the agent reports cannot be checked against tested code.

It must still never print, store or commit a private key or password, and should still send only on pod staging: the comparison is about usability and correctness, not about safety.

## The demonstration

Run the same requests with each plugin, in fresh sessions, and compare:

| Request | Shows |
|---|---|
| "What's our balance?" with an open perp position | Whether the agent gets cash, account value and margin right from hex, 10^18-scaled fields |
| "Show my last 200 trades" | Paging: pod's fills route has no cursor and returns at most 500 per time window |
| "What's NVDA's price?" | Choosing between last price, mark price and oracle price, and converting them |
| "Buy 0.01 NVDA at $140, then cancel it" | Building the order: tick and lot rounding, the deadline on the 500 ms grid, the nonce, the absolute `ttl`, the order id; and checking the real outcome |
| "Is everything working?" | The plugin's status levels against whatever the agent assembles itself |
| "Buy a little of each of these seven markets" | Sizing. A real run on 2026-11-26 bought 0.01 units of each, and gold (about $3,570 a unit against $150 for NVDA) became 60% of the exposure. The plugin has `--usd` and a skill that says sizes are in units; the raw version deliberately has neither, so the demo shows whether the agent notices |

What to record for each run:

| Measure | How |
|---|---|
| Correct? | The answer checked against pod's data converted by the plugin's tested code |
| Time | From request to answer |
| Tokens | From the session's usage |
| Tool calls and permission prompts | Count them |
| Failures | Wrong numbers, wrong routes, orders refused, retries |

Example of the gap, from the dev wallet's NVDA position on 2026-11-26: pod returns `"entry_price": "0x82ff658cf0b3f0000"`, `"margin": "0x10c487e0e36b000"` and `"liquidation_price": "0x0"`. The plugin turns these into $151.03, $0.0755 and "no liquidation price". The raw agent must do that itself, and know that `0x0` means none, not $0.

## When

After the plugin's read sections (Account, Market data) exist, so there is a working product to compare against.
