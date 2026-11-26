# pod-ai

AI tools for pod network. This repo is a Claude Code plugin marketplace holding one plugin, `pod`.

- Specs: [specs/](specs/)
- Plugin: [plugins/pod/](plugins/pod/)

## Install

A person runs these, not the agent: Claude Code's auto mode blocks an agent from installing a plugin itself (seen 2026-11-26).

```
/plugin marketplace add /Users/sabpap/Workspace/Clients/Laurium/pod-ai
/plugin install pod@pod-ai
```

Then **start a new Claude Code session**. Skills load when a session starts, so `/pod:setup` does not appear in the session that installed it.

Then ask the agent to set it up, for example: "Set up the pod plugin with our dev wallet."

## What is built

| Section | Skill | State |
|---|---|---|
| 1 Setup | `/pod:setup` | Built. Read-only steps tested; the real test transaction is run by the user |
| 2 Status | `/pod:status` | Built. Tested read-only; levels checked with a throwaway wallet |
| 3 Account | `/pod:account` | Built. Eight views, tested on the dev wallet and on a busy market-maker account |
| 4 Trading | `/pod:trade` | Built. Every action tested end to end on staging with the dev wallet. Orders can be sized in dollars (`--usd`) |
| Settings | `/pod:settings` | Built. Approval (ask or auto), market band, default resting time; shown by status and setup |
| 5 Market data | `/pod:markets` | Not yet |
| 6 Live updates | `/pod:live` | Not yet |
| 7 Network activity | `/pod:network` | Not yet |

## Tests

| Test | What it checks | Network |
|---|---|---|
| `plugins/pod/tests/units.sh` | Pod's number formats in Bash and in jq (hex and decimal, 10^18 scaling, past 64-bit integers and doubles); time windows; which refused sends count as lasting | None |
| `plugins/pod/tests/smoke.sh` | Setup, status, account and trading plans with a throwaway key and profile, and account views on a public address: error messages, every level reachable without sending, send recording; that no password file is left behind | Pod staging, read-only |
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
