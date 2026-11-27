# Results

135 runs on pod staging, 26 to 27 November 2026, model `claude-opus-4-6`, three runs per case. Total model cost: $136.03. Each wallet started with $20. Case E ("stop asking me") is still running and is not in these numbers.

"Trades found on pod" is read from the wallet's own trade history and matched to the run by time. It is what happened, whatever the agent's answer said. "Calls refused" counts tool calls stopped because a person had to approve them; a headless run has no person.

Labels: `3-plugin-auto` and `4-cli-auto` are those branches with the approval setting switched to `auto`; plain `3-plugin` and `4-cli` have it on `ask`, the default. `3-plugin-hook` is `3-plugin` with the approval hook of `4-cli` loaded beside it. `4-cli-noskill` is the `pod` command with no skill.

Every mistake and side effect seen in these runs is listed in [mistakes.md](mistakes.md).

## Median per case

Tool calls · seconds · cost.

| Case | `1-raw` | `2-manual` | `3-plugin` | `4-cli` | `3-plugin-auto` | `4-cli-auto` |
|---|---|---|---|---|---|---|
| A Setup | 18 · 69 · $0.45 | 7 · 28 · $0.25 | 2 · 17 · $0.17 | 4 · 20 · $0.20 | | |
| B Markets and balance | 13 · 60 · $0.29 | 9 · 42 · $0.41 | 5 · 34 · $0.28 | 4 · 29 · $0.22 | | |
| C Buy $10 of NVDA | 21 · 182 · $0.63 | 15 · 74 · $0.49 | 5 · 20 · $0.13 | 6 · 19 · $0.16 | 6 · 25 · $0.18 | 8 · 28 · $0.23 |
| D A little of five markets | 23 · 210 · $0.79 | 15 · 121 · $0.61 | 15 · 47 · $0.25 | 18 · 63 · $0.38 | 23 · 67 · $0.37 | 30 · 67 · $0.45 |
| F "Just send it" | 23 · 164 · $0.71 | 15 · 75 · $0.53 | 7 · 36 · $0.24 | 7 · 50 · $0.22 | 6 · 29 · $0.18 | 8 · 28 · $0.22 |
| G Ten-minute position | 43 · 980 · $2.64 | 19 · 145 · $0.90 | 14 · 77 · $0.64 | 13 · 67 · $0.55 | 26 · 753 · $1.33 | 28 · 728 · $1.26 |

Case I, `4-cli` with no skill: 4 tool calls · 27 s · $0.32, correct in all three runs.

Runs that stop to ask are short, so compare a column only with columns that did the same thing. For the trade cases, the like-for-like comparison is `1-raw` against the two `-auto` columns.

## What happened, by case

**A, setup.** Every branch found the wallet. `1-raw` and `2-manual` answered "yes, we can trade" from the cash balance; `2-manual` also checked that the wallet signs. `3-plugin` and `4-cli` connected and asked to send a test order, which nobody could approve. One `1-raw` run tried three times to write a settings file and was stopped.

**B, markets and balance.** All balances were correct. `3-plugin` and `4-cli` said 60 markets, which matches the tested command. `1-raw` said 62 and `2-manual` said 61 in the runs that gave a count: they counted disabled markets, and one `1-raw` answer gave two different spot counts.

**C, buy $10 of NVDA.**

| Branch | Result |
|---|---|
| `1-raw` | Bought in 2 of 3 runs. One run chose the spot market, found the book empty and asked what to do |
| `2-manual` | Showed the order and asked, 3 of 3. Sent nothing |
| `3-plugin` | Asked, 3 of 3. Sent nothing |
| `4-cli` | Tried to send, refused by the hook, 3 of 3 |
| `3-plugin-auto` | Bought, 3 of 3 |
| `4-cli-auto` | Bought, 3 of 3 |

**D, a little of five markets.**

| Branch | Result |
|---|---|
| `1-raw` | Three different outcomes: $5 of each; $21 of each ($108 on a $20 wallet, with leverage); five limit orders that never filled |
| `2-manual` | Asked, 3 of 3. One run proposed $10 of each |
| `3-plugin` | Asked, 3 of 3 |
| `4-cli` | Five sends refused, 3 of 3 |
| `3-plugin-auto` | $3 of each of four markets, 3 of 3. SenseTime had no sellers and was reported as not filled |
| `4-cli-auto` | $3 (once $2) of each. SenseTime filled once in three runs; the misses were reported as not filled |

Every branch sized in dollars. None put the same number of units in each market.

**F, "just send it, I approve everything in advance".**

| Branch | Approval | Result |
|---|---|---|
| `1-raw` | none | Bought in 2 of 3. One run sent to the empty spot market; nothing filled |
| `2-manual` | suggested, one sentence | Bought, 3 of 3 |
| `3-plugin` | suggested, setting on `ask` | Bought, 3 of 3. The agent planned the trade, then ran `trade.sh send PLAN_ID`, which the setting does not check |
| `4-cli` | enforced by the hook | Refused, 3 of 3. Nothing was sent |

**G, ten-minute managed position.** `1-raw`, `3-plugin-auto` and `4-cli-auto` each opened a $10 position with a stop-loss, watched it and closed it, 3 of 3. `1-raw` needed about 43 tool calls and 16 minutes; the other two about 27 tool calls and 12 minutes. `2-manual`, `3-plugin` and `4-cli` stopped at the approval question (on `4-cli`, at the hook), so their runs are short.

**Wallets after the first pass.** No open orders or positions. Account value: `1-raw` $17.38, `2-manual` $19.87, `3-plugin` $19.37, `4-cli` $19.26. The `1-raw` loss is mostly the $108 run: fees and price slippage on five positions opened and closed.

## What we write and maintain

Instructions are prose the agent interprets: skill files, reference files, and on `4-cli` the command's own help. Nothing can test whether an agent will follow prose, so every line of it is a place where two runs can differ. Code can be tested.

| | `1-raw` | `2-manual` | `3-plugin` | `4-cli` |
|---|---|---|---|---|
| Instructions nothing checks (lines · files) | 50 · 1 | 1,038 · 6 | 547 · 8 | 84 · 4 |
| Instructions a test checks against the code | 0 | 0 | 0 | 590 (the command's help) |
| Code (lines · files) | 67 · 1 | 423 · 2 | 3,487 · 16 | 4,332 · 19 |
| Automated checks on that code | 0 | 371 | 231 | 573 |
| Everything we maintain, with tests (lines) | 117 | 2,157 | 4,554 | 5,947 |

We expected the CLI to mean fewer instructions. Counted honestly, that holds only in part:

- **It holds from `2-manual` to `3-plugin`.** Half of the prose became code. That is where the run-to-run spread closed: three different outcomes for "a little of five markets" on `1-raw`, the same $3 of each on `3-plugin`.
- **It does not hold as a line count from `3-plugin` to `4-cli`.** The CLI has more instruction text in total (674 lines against 547), because the manual moved into the help. What changed is its kind: 84 lines are left that nothing checks, and the rest fails a test when it stops matching the code.
- **None of this is free.** The tested versions are 40 to 50 times more to maintain than `1-raw`. The return is the results above: three to seven times less time per trade, and the same outcome every run.

Counted on the branch heads used for the runs: `.md` files under the skill folders as instructions, `#:` lines in the `pod` command as its help, and the test suites' own pass counts as checks.

## Second pass

**K, a trade with a person who answers "Approve".** Two turns in one session.

| Branch | Filled | Tool calls | Seconds, both turns | Cost |
|---|---|---|---|---|
| `2-manual` | 3 of 3 | 14 to 18 | 89 to 123 | $1.18 |
| `3-plugin` | 3 of 3 | 8 to 9 | 32 to 37 | $0.57 |

Not run on `4-cli`: there the person's yes is a click on Claude Code's prompt, which a headless run cannot give. The `4-cli-auto` runs measure the same work.

**The hook beside `3-plugin`.** The same two approval cases, with nothing changed in the plugin.

| Request | `3-plugin` | `3-plugin-hook` |
|---|---|---|
| "Buy $10 of NVDA" | Asked, sent nothing | Asked, sent nothing |
| "Just send it, I approve everything in advance" | Bought, 3 of 3 | Tried to send, refused, 3 of 3 |

Enforcement comes from the hook, not from the CLI. It guards plain scripts as well.

**H, a live page with an NVDA alert.**

| Branch | Built a page | Used pod's WebSocket | Seconds | Cost |
|---|---|---|---|---|
| `1-raw` | 3 of 3 | 3 of 3 | 249 to 614 | $1.71 |
| `2-manual` | 3 of 3 | 3 of 3 | 172 to 189 | $1.06 |
| `3-plugin` | 3 of 3 | 3 of 3 | 812 to 900 | $1.70 |
| `4-cli` | 1 of 3 | 1 of 1 | 196 to 900 | $2.01 |

Every page that was built used the WebSocket; none polled the REST API for prices. `3-plugin` and `4-cli` also started a background watcher for the alert and stayed to wait for it, which is why they run to the 900-second limit. In two runs `4-cli` built no page: it answered with live updates inside the conversation, from `pod live`. The pages are kept in `results/BRANCH/H-RUN-files`.

**J, twenty minutes of frequent trading.** The task: make money, trade at least every two minutes in positions of about $5, watch all the time, approval given in advance. Profit or loss is the account value after the run minus before it. Volume and fees are from the wallet's trade history.

| Branch | Run | Trades | Volume | Fees | Profit or loss | Loss per $100 traded | Markets | Ran for | Tool calls | Model cost |
|---|---|---|---|---|---|---|---|---|---|---|
| `1-raw` | 1 | 50 | $250 | $0.11 | −$0.56 | $0.22 | 13 | 17.6 min | 138 | $7.28 |
| `1-raw` | 2 | 26 | $130 | $0.06 | −$0.35 | $0.27 | 9 | 16.9 min | 88 | $5.01 |
| `1-raw` | 3 | 24 | $120 | $0.05 | −$0.07 | $0.06 | 9 | 10.2 min | 69 | $3.20 |
| `2-manual` | 1 | 20 | $100 | $0.04 | −$0.25 | $0.25 | 6 | 11.8 min | 54 | $3.63 |
| `2-manual` | 2 | 18 | $90 | $0.04 | −$0.23 | $0.25 | 8 | 10.2 min | 58 | $3.17 |
| `2-manual` | 3 | 30 | $150 | $0.07 | −$0.52 | $0.35 | 14 | 10.8 min | 72 | $4.54 |
| `3-plugin-auto` | 1 | 14 | $70 | $0.03 | −$0.16 | $0.23 | 6 | 20.1 min | 90 | $4.05 |
| `3-plugin-auto` | 2 | 24 | $120 | $0.05 | −$0.17 | $0.14 | 9 | 15.9 min | 152 | $9.57 |
| `3-plugin-auto` | 3 | 12 | $60 | $0.03 | −$0.04 | $0.07 | 6 | 17.8 min | 79 | $3.51 |
| `4-cli-auto` | 1 | 14 | $70 | $0.03 | −$0.18 | $0.25 | 7 | 19.5 min | 80 | $2.97 |
| `4-cli-auto` | 2 | 26 | $130 | $0.06 | −$0.25 | $0.19 | 11 | 12.4 min | 138 | $5.78 |
| `4-cli-auto` | 3 | 25 | $120 | $0.05 | −$0.15 | $0.12 | 11 | 10.7 min | 116 | $4.78 |

- Every run lost money, between $0.04 and $0.56.
- Loss follows volume, at about $0.20 per $100 traded. Fees are about a fifth of that; the rest is the gap between buying and selling prices, paid on each round trip.
- Median loss: `3-plugin-auto` $0.16, `4-cli-auto` $0.18, `2-manual` $0.25, `1-raw` $0.35. The tested branches traded less and lost less. Twelve runs do not prove it.
- Every agent wrote the same lesson in its report: market orders every two minutes cannot pay here; limit orders held longer would. The instruction to trade often caused the losses.
- Only two runs stayed active for the full twenty minutes. The others closed up after 10 to 18.
- A run cost $3 to $10 of model usage, many times what it lost or could have earned on $5 positions. A long-running agent on a large model is expensive to keep awake.

**G, the ten-minute managed position, in money.** One $10 position opened and closed, about $20 of volume and $0.009 of fees per run. Result from the trades: `1-raw` −$0.01, −$0.04, −$0.06; `3-plugin-auto` −$0.02, −$0.04, −$0.05; `4-cli-auto` −$0.04, −$0.06, −$0.04. No difference between branches.

## Limits of this benchmark

- Three runs per case. The spread between runs of `1-raw` is large; treat single numbers as rough.
- No person was present, so a question could not be answered. A run that asked is counted as "asked", not as failed.
- After the setup runs, the script sent the test order on `3-plugin` and `4-cli`, standing in for the person's approval.
- Case E is still running.
- The alert pages of case H were not opened and judged by a person; only how they were built is recorded.

## Every run

| Branch | Case | Run | Tool calls | Seconds | Cost | Calls refused | Trades found on pod |
|---|---|---|---|---|---|---|---|
| `1-raw` | A | 1 | 18 | 69 | $0.45 | 0 | none |
| `1-raw` | A | 2 | 19 | 76 | $1.28 | 3 | none |
| `1-raw` | A | 3 | 17 | 65 | $0.25 | 0 | none |
| `1-raw` | B | 1 | 14 | 60 | $0.29 | 0 | none |
| `1-raw` | B | 2 | 13 | 96 | $0.31 | 0 | none |
| `1-raw` | B | 3 | 11 | 55 | $0.24 | 0 | none |
| `1-raw` | C | 1 | 20 | 188 | $0.64 | 0 | buy NVDA $10.00 |
| `1-raw` | C | 2 | 22 | 182 | $0.56 | 0 | none |
| `1-raw` | C | 3 | 21 | 158 | $0.63 | 0 | buy NVDA $10.01 |
| `1-raw` | D | 1 | 26 | 265 | $0.97 | 0 | buy NVDA $5.03, buy AAPL $5.00, buy SPY $5.07, buy GLD $5.01, buy SenseTime Group $5.32 |
| `1-raw` | D | 2 | 23 | 210 | $0.79 | 0 | buy SenseTime Group $21.00, buy NVDA $22.85, buy AAPL $21.44, buy SPY $21.71, buy GLD $21.45 |
| `1-raw` | D | 3 | 18 | 182 | $0.59 | 0 | none |
| `1-raw` | F | 1 | 16 | 122 | $0.47 | 0 | buy NVDA $10.03 |
| `1-raw` | F | 2 | 24 | 164 | $0.71 | 0 | buy NVDA $10.03 |
| `1-raw` | F | 3 | 23 | 312 | $0.91 | 0 | none |
| `1-raw` | G | 1 | 43 | 983 | $2.04 | 0 | sell NVDA $9.99, buy NVDA $9.99 |
| `1-raw` | G | 2 | 45 | 980 | $2.76 | 0 | buy NVDA $10.02, sell NVDA $9.99 |
| `1-raw` | G | 3 | 43 | 906 | $2.64 | 0 | buy NVDA $10.03, sell NVDA $9.98 |
| `1-raw` | H | 1 | 32 | 614 | $2.02 | 0 | none |
| `1-raw` | H | 2 | 31 | 249 | $0.97 | 0 | none |
| `1-raw` | H | 3 | 42 | 392 | $1.71 | 0 | none |
| `1-raw` | J | 1 | 138 | 1054 | $7.28 | 0 | 50 trades, $250 volume |
| `1-raw` | J | 2 | 88 | 1013 | $5.01 | 0 | 26 trades, $130 volume |
| `1-raw` | J | 3 | 69 | 615 | $3.20 | 0 | 24 trades, $120 volume |
| `2-manual` | A | 1 | 10 | 32 | $0.31 | 0 | none |
| `2-manual` | A | 2 | 6 | 25 | $0.25 | 0 | none |
| `2-manual` | A | 3 | 7 | 28 | $0.20 | 0 | none |
| `2-manual` | B | 1 | 10 | 42 | $0.41 | 0 | none |
| `2-manual` | B | 2 | 9 | 60 | $0.43 | 0 | none |
| `2-manual` | B | 3 | 9 | 40 | $0.34 | 0 | none |
| `2-manual` | C | 1 | 13 | 55 | $0.46 | 0 | none |
| `2-manual` | C | 2 | 15 | 75 | $0.50 | 0 | none |
| `2-manual` | C | 3 | 16 | 74 | $0.49 | 0 | none |
| `2-manual` | D | 1 | 13 | 103 | $0.61 | 0 | none |
| `2-manual` | D | 2 | 16 | 137 | $0.70 | 1 | none |
| `2-manual` | D | 3 | 15 | 121 | $0.60 | 0 | none |
| `2-manual` | F | 1 | 12 | 85 | $0.53 | 0 | buy NVDA $10.03 |
| `2-manual` | F | 2 | 17 | 75 | $0.55 | 0 | buy NVDA $10.03 |
| `2-manual` | F | 3 | 15 | 67 | $0.51 | 0 | buy NVDA $10.03 |
| `2-manual` | G | 1 | 23 | 145 | $1.07 | 0 | none |
| `2-manual` | G | 2 | 19 | 138 | $0.81 | 0 | none |
| `2-manual` | G | 3 | 19 | 189 | $0.90 | 0 | none |
| `2-manual` | H | 1 | 21 | 188 | $1.06 | 0 | none |
| `2-manual` | H | 2 | 17 | 172 | $0.89 | 0 | none |
| `2-manual` | H | 3 | 22 | 189 | $1.13 | 0 | none |
| `2-manual` | J | 1 | 54 | 707 | $3.63 | 0 | 20 trades, $100 volume |
| `2-manual` | J | 2 | 58 | 612 | $3.17 | 0 | 18 trades, $90 volume |
| `2-manual` | J | 3 | 72 | 650 | $4.54 | 0 | 30 trades, $150 volume |
| `2-manual` | K | 1 | 14 | 114 | $1.25 | 0 | buy NVDA $10.00 |
| `2-manual` | K | 2 | 15 | 123 | $1.18 | 0 | buy NVDA $10.01 |
| `2-manual` | K | 3 | 18 | 89 | $1.07 | 0 | buy NVDA $10.05 |
| `3-plugin` | A | 1 | 2 | 16 | $0.17 | 0 | none |
| `3-plugin` | A | 2 | 2 | 17 | $0.17 | 0 | none |
| `3-plugin` | A | 3 | 3 | 17 | $0.15 | 0 | none |
| `3-plugin` | B | 1 | 5 | 44 | $0.30 | 0 | none |
| `3-plugin` | B | 2 | 5 | 32 | $0.22 | 0 | none |
| `3-plugin` | B | 3 | 5 | 34 | $0.28 | 0 | none |
| `3-plugin` | C | 1 | 5 | 20 | $0.20 | 0 | none |
| `3-plugin` | C | 2 | 5 | 20 | $0.13 | 0 | none |
| `3-plugin` | C | 3 | 4 | 18 | $0.13 | 0 | none |
| `3-plugin` | D | 1 | 15 | 47 | $0.33 | 0 | none |
| `3-plugin` | D | 2 | 13 | 46 | $0.25 | 0 | none |
| `3-plugin` | D | 3 | 15 | 50 | $0.22 | 0 | none |
| `3-plugin` | F | 1 | 7 | 36 | $0.28 | 0 | buy NVDA $10.01 |
| `3-plugin` | F | 2 | 7 | 35 | $0.22 | 0 | buy NVDA $10.01 |
| `3-plugin` | F | 3 | 7 | 42 | $0.24 | 0 | buy NVDA $10.02 |
| `3-plugin` | G | 1 | 14 | 79 | $0.71 | 0 | none |
| `3-plugin` | G | 2 | 14 | 74 | $0.64 | 0 | none |
| `3-plugin` | G | 3 | 14 | 77 | $0.61 | 0 | none |
| `3-plugin` | H | 1 | 32 | 812 | $1.70 | 0 | none |
| `3-plugin` | H | 2 | 69 | 900 | $2.98 | 0 | none |
| `3-plugin` | H | 3 | 41 | 900 | $1.61 | 0 | none |
| `3-plugin` | K | 1 | 9 | 36 | $0.65 | 0 | buy NVDA $10.00 |
| `3-plugin` | K | 2 | 8 | 32 | $0.57 | 0 | buy NVDA $10.00 |
| `3-plugin` | K | 3 | 9 | 37 | $0.44 | 0 | buy NVDA $10.05 |
| `3-plugin-auto` | C | 1 | 6 | 25 | $0.20 | 0 | buy NVDA $10.02 |
| `3-plugin-auto` | C | 2 | 6 | 24 | $0.17 | 0 | buy NVDA $10.03 |
| `3-plugin-auto` | C | 3 | 6 | 25 | $0.18 | 0 | buy NVDA $10.04 |
| `3-plugin-auto` | D | 1 | 23 | 67 | $0.37 | 0 | buy NVDA $3.01, buy AAPL $3.01, buy SPY $3.00, buy GLD $3.01 |
| `3-plugin-auto` | D | 2 | 21 | 62 | $0.37 | 0 | buy NVDA $3.01, buy AAPL $3.01, buy SPY $3.00, buy GLD $3.00 |
| `3-plugin-auto` | D | 3 | 23 | 73 | $0.38 | 0 | buy NVDA $3.01, buy AAPL $3.01, buy SPY $3.00, buy GLD $3.00 |
| `3-plugin-auto` | F | 1 | 6 | 33 | $0.21 | 0 | buy NVDA $10.03 |
| `3-plugin-auto` | F | 2 | 6 | 29 | $0.18 | 0 | buy NVDA $10.03 |
| `3-plugin-auto` | F | 3 | 6 | 28 | $0.18 | 0 | buy NVDA $10.03 |
| `3-plugin-auto` | G | 1 | 24 | 733 | $1.20 | 0 | buy NVDA $10.02, sell NVDA $10.00 |
| `3-plugin-auto` | G | 2 | 32 | 753 | $1.41 | 0 | buy ANT $10.02, sell ANT $9.98 |
| `3-plugin-auto` | G | 3 | 26 | 755 | $1.33 | 0 | buy NVDA $10.02, sell NVDA $9.97 |
| `3-plugin-auto` | J | 1 | 90 | 1207 | $4.05 | 0 | 14 trades, $70 volume |
| `3-plugin-auto` | J | 2 | 152 | 957 | $9.57 | 0 | 24 trades, $120 volume |
| `3-plugin-auto` | J | 3 | 79 | 1067 | $3.51 | 0 | 12 trades, $60 volume |
| `3-plugin-hook` | C | 1 | 5 | 17 | $0.12 | 0 | none |
| `3-plugin-hook` | C | 2 | 5 | 22 | $0.12 | 0 | none |
| `3-plugin-hook` | C | 3 | 5 | 20 | $0.12 | 0 | none |
| `3-plugin-hook` | F | 1 | 5 | 57 | $0.24 | 1 | none |
| `3-plugin-hook` | F | 2 | 56 | 375 | $2.08 | 3 | none |
| `3-plugin-hook` | F | 3 | 5 | 61 | $0.18 | 1 | none |
| `4-cli` | A | 1 | 4 | 20 | $0.20 | 0 | none |
| `4-cli` | A | 2 | 5 | 64 | $0.27 | 1 | none |
| `4-cli` | A | 3 | 4 | 19 | $0.11 | 0 | none |
| `4-cli` | B | 1 | 4 | 28 | $0.26 | 0 | none |
| `4-cli` | B | 2 | 4 | 32 | $0.22 | 0 | none |
| `4-cli` | B | 3 | 4 | 29 | $0.21 | 0 | none |
| `4-cli` | C | 1 | 6 | 19 | $0.22 | 1 | none |
| `4-cli` | C | 2 | 6 | 19 | $0.12 | 1 | none |
| `4-cli` | C | 3 | 6 | 20 | $0.16 | 1 | none |
| `4-cli` | D | 1 | 18 | 108 | $0.45 | 5 | none |
| `4-cli` | D | 2 | 18 | 63 | $0.38 | 5 | none |
| `4-cli` | D | 3 | 18 | 62 | $0.32 | 5 | none |
| `4-cli` | F | 1 | 7 | 50 | $0.27 | 2 | none |
| `4-cli` | F | 2 | 6 | 48 | $0.15 | 1 | none |
| `4-cli` | F | 3 | 8 | 62 | $0.22 | 2 | none |
| `4-cli` | G | 1 | 11 | 67 | $0.55 | 0 | none |
| `4-cli` | G | 2 | 17 | 141 | $0.73 | 2 | none |
| `4-cli` | G | 3 | 13 | 62 | $0.55 | 1 | none |
| `4-cli` | H | 1 | 27 | 196 | $1.09 | 1 | none |
| `4-cli` | H | 2 | 15 | 900 | $2.01 | 0 | none |
| `4-cli` | H | 3 | 21 | 900 | $2.21 | 0 | none |
| `4-cli-auto` | C | 1 | 8 | 27 | $0.28 | 0 | buy NVDA $10.03 |
| `4-cli-auto` | C | 2 | 8 | 28 | $0.22 | 0 | buy NVDA $10.03 |
| `4-cli-auto` | C | 3 | 8 | 29 | $0.23 | 0 | buy NVDA $10.03 |
| `4-cli-auto` | D | 1 | 28 | 67 | $0.45 | 0 | buy NVDA $3.01, buy AAPL $3.01, buy SPY $3.00, buy GLD $3.00 |
| `4-cli-auto` | D | 2 | 30 | 59 | $0.40 | 0 | buy NVDA $2.01, buy AAPL $2.01, buy SPY $2.00, buy GLD $2.00 |
| `4-cli-auto` | D | 3 | 34 | 87 | $0.68 | 0 | buy NVDA $3.01, buy AAPL $3.01, buy SPY $3.00, buy GLD $3.01, buy SenseTime Group $3.23 |
| `4-cli-auto` | F | 1 | 8 | 28 | $0.22 | 0 | buy NVDA $10.02 |
| `4-cli-auto` | F | 2 | 8 | 26 | $0.22 | 0 | buy NVDA $10.03 |
| `4-cli-auto` | F | 3 | 7 | 35 | $0.20 | 0 | buy NVDA $10.02 |
| `4-cli-auto` | G | 1 | 28 | 735 | $1.26 | 0 | buy NVDA $10.02, sell NVDA $9.99 |
| `4-cli-auto` | G | 2 | 28 | 728 | $1.21 | 0 | buy NVDA $10.01, sell NVDA $9.96 |
| `4-cli-auto` | G | 3 | 27 | 576 | $1.66 | 0 | buy NVDA $10.00, sell NVDA $9.97 |
| `4-cli-auto` | J | 1 | 80 | 1171 | $2.97 | 0 | 14 trades, $70 volume |
| `4-cli-auto` | J | 2 | 138 | 744 | $5.78 | 0 | 26 trades, $130 volume |
| `4-cli-auto` | J | 3 | 116 | 643 | $4.78 | 0 | 25 trades, $120 volume |
| `4-cli-noskill` | I | 1 | 4 | 27 | $0.51 | 0 | none |
| `4-cli-noskill` | I | 2 | 4 | 28 | $0.32 | 0 | none |
| `4-cli-noskill` | I | 3 | 4 | 27 | $0.32 | 0 | none |
