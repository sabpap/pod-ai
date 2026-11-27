# pod-ai

AI tools for pod network. This repo is a Claude Code plugin marketplace holding one plugin, `pod`.

- Specs: [specs/](specs/)
- Plugin: [plugins/pod/](plugins/pod/)

## Install

A person runs these, not the agent: Claude Code's auto mode blocks an agent from installing a plugin itself (seen 2026-11-26).

First get this branch, in a terminal:

```
git clone -b 3-plugin git@github.com:sabpap/pod-ai.git pod-ai-3-plugin
```

Then, in Claude Code, with the full path of that folder:

```
/plugin marketplace add /full/path/to/pod-ai-3-plugin
/plugin install pod@pod-ai
```

You need: Foundry (`cast`), `jq`, `curl`, `bc`, Node.js 22 or later for live updates, and a wallet with funds on pod staging, as a Foundry keystore with its password in the macOS Keychain or as a private key in an environment variable.

Then **start a new Claude Code session**. Skills load when a session starts, so `/pod:setup` does not appear in the session that installed it.

Then ask the agent to set it up, for example: "Set up the pod plugin with our dev wallet." After that, ask for anything on pod in words: "what do I have on pod?", "NVDA order book", "buy $10 of NVDA", "tell me when gold drops below 3,400".

To update after a new version (the version is in [plugin.json](plugins/pod/.claude-plugin/plugin.json)), a person runs these in a terminal, then starts a new session:

```
claude plugin marketplace update pod-ai
claude plugin update pod@pod-ai
```

To try the plugin from this folder without installing it: `claude --plugin-dir plugins/pod`.

## Skills

Four skills. A skill is split off only when a person will type its name; everything said in words goes through the main skill.

| Skill | Who starts it | What it does |
|---|---|---|
| `/pod:use` | The agent, whenever a request is about pod; a person can also type it, e.g. `/pod:use NVDA order book` | Accounts, markets, trading and live updates. Its `SKILL.md` holds the order of work and the rules that hold everywhere; the detail is in [references/](plugins/pod/skills/use/references/): `account.md`, `markets.md`, `trade.md`, `live.md` |
| `/pod:setup` | The person, or the agent when no wallet is connected | Connect a wallet, prove it can send with one test transaction, show or remove the connection |
| `/pod:status` | The person, or the agent when the state is unknown | Can the agent act on pod right now, and if not, why not |
| `/pod:settings` | Only the person | Show or change approval (`ask` or `auto`), the market-order band and the default resting time |

## What is built

| Section | Where | State |
|---|---|---|
| 1 Setup | `/pod:setup` | Built. Read-only steps tested; the real test transaction is run by the user |
| 2 Status | `/pod:status` | Built. Tested read-only; levels checked with a throwaway wallet |
| 3 Account | `/pod:use`, `references/account.md` | Built. Eight views, tested on the dev wallet and on a busy market-maker account |
| 4 Trading | `/pod:use`, `references/trade.md` | Built. Every action tested end to end on staging with the dev wallet. Orders can be sized in dollars (`--usd`) |
| Settings | `/pod:settings` | Built. Approval (ask or auto), market band, default resting time; shown by status and setup |
| 5 Market data | `/pod:use`, `references/markets.md` | Built. Markets, movers, one market, the book with the cost of a size, price bars, per-round history |
| 6 Live updates | `/pod:use`, `references/live.md` | Built. A background listener for nine channels with conditions; needs Node.js 22 or later |
| 7 Network activity | | Not yet |

## Architecture, strengths and weaknesses

The plugin is skills plus Bash scripts. The skills tell the agent which script to run for each request and how to read the answer; the scripts in [plugins/pod/scripts/](plugins/pod/scripts/) make plain REST, WebSocket and JSON-RPC calls to pod staging, sign with the wallet through Foundry's `cast`, and print JSON. There are no hooks and no MCP server. Nothing here needs a plugin except distribution and updates: the plugin ships the skills and scripts together and updates them by version. As plain skills in a project's `.claude/skills/`, only the script paths (`${CLAUDE_PLUGIN_ROOT}/scripts/`) would change.

**Strengths**

- One main skill, `/pod:use`: the agent picks it for any pod request, and reads only the reference it needs. Until then, only the skill descriptions sit in the context.
- The skills a person types (`/pod:setup`, `/pod:status`, `/pod:settings`) stay short commands.
- Every script answers in one JSON shape, with a plain `error` and a `fix` when something goes wrong, and is tested on its own (see Tests).
- Nothing runs in the background except what the agent starts on purpose: a live listener or the follow-up of a sent trade.

**Weaknesses**

- **Approval is suggested, not enforced.** The `approval` setting and the Approve / Deny question are instructions to the agent. `trade.sh` refuses the one-step `--send` shortcut while the setting is `ask`, but `trade.sh send PLAN_ID` sends any saved plan without checking that a person approved it. The agent can also run `profile.sh set approval auto` itself: `/pod:settings` is startable only by the person (`disable-model-invocation: true`), and the main skill forbids the change, but nothing in the scripts stops it. A real lock would need a hook or a separate approval step outside the agent's reach.
- **"Stop asking me" on its own may not reach the plugin.** In a headless test (2026-11-26), "On pod, stop asking me before every trade" did not load the main skill, `/pod:use`: the agent agreed in words, and with auto-memory on it saved "trade without confirmation" as a memory. Once the main skill was loaded in the same conversation, the agent answered correctly that the user must type `/pod:settings approval auto`. The setting itself did not change in either case, and every trade plan still says `needs_approval: true`.
- The scripts are reachable only from Claude Code (they rely on `${CLAUDE_PLUGIN_ROOT}`, the Bash tool and, for live updates, background commands). Another harness or a web page has to call pod itself; [references/live.md](plugins/pod/skills/use/references/live.md) documents pod's live protocol for that case.
- Staging only, one wallet at a time, and the dev wallet needs macOS (the password sits in the Keychain) or a private key in an environment variable.
- The agent must read the right reference before acting. If it skips it, it can still run a script, but it may miss a rule that lives only in the reference, such as the exact approval question.

## Tests

| Test | What it checks | Network |
|---|---|---|
| `plugins/pod/tests/units.sh` | Pod's number formats in Bash and in jq (hex and decimal, 10^18 scaling, past 64-bit integers and doubles); time windows; which refused sends count as lasting; that a failed nonce lookup stops a send while a real nonce 0 passes | None |
| `node plugins/pod/tests/live-units.mjs` | The live listener's decoding (exact amounts, prices, book, bars, orders, activity, positions, triggers) and its conditions | None |
| `plugins/pod/tests/live-reconnect.sh` | The listener against a fake pod server that drops the connection and closes the stream: it resumes from the last round with no gap or repeat. Needs Deno | Local fake, plus staging's market list |
| `plugins/pod/tests/smoke.sh` | Setup, status, account, markets and trading plans with a throwaway key and profile, account views on a public address, and short live listeners: error messages, every level reachable without sending, send recording; that no password file is left behind | Pod staging, read-only |
| `plugins/pod/scripts/test-transaction.sh --yes` | A real order and cancel with the connected wallet | Pod staging, sends two transactions |

## Secrets

Nothing secret belongs in this repo: no private keys, keystores, seed phrases, passwords or `.env` files.

- [`.gitignore`](.gitignore) keeps out key, wallet, environment and credential files, and the plugin's own profile and temp files.
- [gitleaks](https://github.com/gitleaks/gitleaks) checks every commit with pod-specific rules in [`.gitleaks.toml`](.gitleaks.toml) (wallet private keys, encrypted keystores, seed phrases) on top of its defaults. Turn the hook on once per clone:
  ```
  brew install gitleaks
  git config core.hooksPath .githooks
  ```
- Full scan at any time: `gitleaks dir . --config .gitleaks.toml`.
