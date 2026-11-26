# pod-ai: the manual (branch `2-manual`)

This branch gives an AI agent pod network as **a manual**: one plain Agent Skill that knows pod's API and its traps, plus two small tested scripts for the two steps agents most often get wrong. The agent makes every call itself and reads pod's JSON unchanged.

It is one of four ways to give an agent pod, from total freedom to a product. The other approaches are in branches `1-raw`, `3-plugin` and `4-cli`, and they are compared on `main`.

## What this approach is

| Part | What it does |
|---|---|
| [`SKILL.md`](.claude/skills/pod/SKILL.md) | What pod is, when to use the skill, eight fixed rules, and which reference to read for which request |
| [`references/basics.md`](.claude/skills/pod/references/basics.md) | Endpoints, chain id, identifiers, number formats (10^18 scaling, hex or decimal, past 64 bits), "0 means none", microseconds and the exceptions, the auction cycle (accepted is not filled), the `timestamp` freshness parameter, the six paging styles, error codes |
| [`references/account.md`](.claude/skills/pod/references/account.md) | The REST route for each account question, what every field means, paging, numbers worth working out, account health and nonces |
| [`references/markets.md`](.claude/skills/pod/references/markets.md) | Markets and their rules, stats, which price to quote, the order book, the cost of a size, candles, per-round history, network activity |
| [`references/trading.md`](.claude/skills/pod/references/trading.md) | The full recipe for an order: rules, rounding on the safe side, sizing by money, the deadline on the 500 ms grid, the absolute `ttl`, nonces, every contract function with its exact signature, flags, triggers, batches, then confirming acceptance and the real outcome |
| [`references/live.md`](.claude/skills/pod/references/live.md) | WebSocket channels, `eth_subscribe`, catching up with `since`, the 2.3-hour replay limit, repeats, reconnecting and resuming, and a short listener to adapt |
| [`scripts/pod-number.sh`](.claude/skills/pod/scripts/pod-number.sh) | Exact conversion of pod's numbers both ways (`from-pod`, `to-pod`, `int`) and of microsecond times (`time`, `us`) |
| [`scripts/pod-send.sh`](.claude/skills/pod/scripts/pod-send.sh) | Signs and sends **one** transaction the agent built: finds the wallet, checks the chain is pod staging, reads the nonce, signs with `cast`, checks the signed bytes match the request, sends with `eth_sendRawTransaction`, and returns the hash and `pod_getTxStatus` as JSON. `--dry-run` stops after signing; `--check` is the wallet check |

There is no profile, no settings, no status levels, no plans, no listener and no account or market scripts. Approval is one sentence in `SKILL.md` ("before sending anything that trades, show the user what will be sent and ask"). **Nothing enforces it.**

## Setup

**Tools.** Foundry's `cast`, `curl` and `jq` (`brew install foundry jq`; `bc` ships with macOS). Node.js 22 or later only for live listeners and the tests.

**Start a session.** Open Claude Code in this folder:

```
cd pod-ai        # on branch 2-manual
claude
```

The skill lives in `.claude/skills/pod/`, so Claude Code loads it with no install. To use it in every project, copy it to your user skills:

```
cp -R .claude/skills/pod ~/.claude/skills/
```

The skill is a standard Agent Skill (a folder with `SKILL.md`), so any agent that accepts skills can load it.

**If the `pod` plugin from `3-plugin` is installed globally, disable it while testing this branch** (`/plugin`, or `claude plugin disable pod@pod-ai`). Otherwise the session silently gets the plugin's skills as well, and the comparison is void.

**A wallet** (only for trading; reading needs none). The user provides it outside the chat. Never paste a key into the conversation.

- A private key in the environment of the shell that starts Claude Code: `export POD_PRIVATE_KEY=…`
- Or a Foundry keystore: `export POD_KEYSTORE=NAME` (in `~/.foundry/keystores`), with its password stored once in the macOS Keychain by the user: `security add-generic-password -s foundry-keystore -a NAME -w`. This is the same entry the `3-plugin` dev wallet uses. On other systems, `POD_KEYSTORE_PASSWORD_FILE` names a file holding the password.

Check it: `.claude/skills/pod/scripts/pod-send.sh --check`.

## Example requests

- "What's the balance of 0x035A9E2f3ED8bAAD656E66BF3f0071da40DcDa70?"
- "Show my positions and how far each is from liquidation."
- "What's NVDA's price? And the gold spread?"
- "Show my last 200 trades."
- "Top movers today."
- "Buy $10 of NVDA at market." / "Buy 0.01 NVDA at 140, then cancel it."
- "Put a stop-loss at 130 on my NVDA position."
- "Tell me when NVDA drops below 140."

## Files

```
.claude/skills/pod/
  SKILL.md
  references/  basics.md  account.md  markets.md  trading.md  live.md
  scripts/     pod-number.sh  pod-send.sh
tests/
  number.sh  send.sh  fake-rpc.mjs  check-skill.sh  staging.sh  staging-live.mjs
```

## Tests

| Test | What it checks | Network |
|---|---|---|
| `tests/number.sh` | Conversions both ways: hex and decimal, signed, zero, past 2^64 and past double precision, uint256 max, round trips, microsecond times, refusals (more than 18 decimals, exponents, seconds passed as microseconds) | None |
| `tests/send.sh` | `pod-send.sh` with a throwaway key in a variable and a throwaway keystore in a temp folder (password from a file, and from a stand-in for the Keychain): the wallet check, no wallet, ambiguous wallets, dry runs that decode to exactly the request, the same bytes from both wallet types, wrong chain refused before signing, sending and pod's refusals (`996`, `3` with its reason decoded, `-32025`, executed but failed), and that no output ever holds the key or password | A local fake pod (`tests/fake-rpc.mjs`); nothing reaches pod |
| `tests/check-skill.sh` | `SKILL.md` frontmatter (name, description length and trigger words), every link and anchor resolves, exactly two executable scripts, no trace of the plugin | None |
| `tests/staging.sh` | Every REST route, JSON-RPC method and WebSocket channel the references name, against staging, with the shapes and units the references state; a `pod-send.sh` dry run (signed, never sent); the listener sample in `live.md` run as written | Pod staging, read-only |

## Architecture, strengths and weaknesses

**How it works.** The agent reads `SKILL.md`, picks a reference, and calls pod's REST, JSON-RPC and WebSocket APIs with `curl` (or its own code). It converts numbers with `pod-number.sh` and signs with `pod-send.sh`. Everything between, from choosing the route to rounding, sizing, confirming and explaining, the agent assembles from the manual each time.

**Strengths**

- **It knows pod's traps.** The manual was distilled from the tested `3-plugin` scripts and checked against staging: 10^18 numbers in mixed hex and decimal, `0x0` meaning none, seconds hiding among microseconds, fills without a cursor, state channels that stay silent without `since`, order ids that are not transaction hashes, deadlines on the 500 ms grid, the absolute `ttl`, sizes in units not dollars, accepted not being filled.
- **Tested code for the two riskiest steps.** Number conversion is exact and unit-tested. Signing produced byte-identical transactions to the plugin's signer for the same orders, cancels, triggers and batches, refuses any chain but pod staging before signing, checks the signed bytes against the request, and never prints the key.
- **Flexible.** Any route, any parameter, any combination: nothing is limited to the views someone thought of in advance.
- **Portable.** A plain skill folder and two Bash scripts. Any agent that accepts skills can use it.

**Weaknesses**

- **The manual must be kept in step with pod by hand.** When pod changes a route or a field, nothing fails until an agent gets it wrong.
- **Every workflow is assembled again each time.** Finding a market, rounding, the deadline, the preview, confirming the outcome: the agent rebuilds them in every session, which costs time and tokens and leaves room for slips the manual cannot catch.
- **Results are raw JSON.** The agent converts and interprets pod's answers itself; nothing checks its arithmetic beyond the conversion script.
- **No state, settings or status.** No saved wallet (it is named by environment variable on every call), no "ready to trade" level, no record of past sends, no default band or resting time.
- **Approval is only a sentence.** The skill asks the agent to show the trade and ask first. Nothing stops an agent that does not.
- **`pod-send.sh` signs whatever call it is given** on pod staging, including calls the manual does not cover.
- With a private key in the environment, `cast` receives the key as an argument, so the user's own processes can see it while `cast` runs (the same as the plugin). A keystore has no such exposure.

## Secrets

Nothing secret belongs in this repo: no private keys, keystores, seed phrases, passwords or `.env` files.

- [`.gitignore`](.gitignore) keeps out key, wallet, environment and credential files.
- [gitleaks](https://github.com/gitleaks/gitleaks) checks every commit with pod-specific rules in [`.gitleaks.toml`](.gitleaks.toml) on top of its defaults. Turn the hook on once per clone:
  ```
  brew install gitleaks
  git config core.hooksPath .githooks
  ```
- Full scan at any time: `gitleaks dir . --config .gitleaks.toml`.
- The tests make throwaway keys and keystores in a private temp folder and delete them when they finish.
