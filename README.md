# pod-ai: 1-raw

The agent uses pod network's raw API, guided only by pod's own docs.

This is the loosest way to give an agent pod: it works with pod's API directly. There is one Agent Skill with a short overview of pod, the links to pod's docs, and one script that finds the wallet. Everything else the agent works out from the docs, every time.

This is one of four approaches, one branch each: `1-raw` (this one), `2-manual`, `3-plugin` and `4-cli`. They are compared on `main`.

## What is here

```
.claude/skills/pod/
  SKILL.md                 what pod is, the staging endpoints, where the docs are, two rules
  scripts/check-wallet.sh  finds the wallet and prints its address, never the key
```

## Setup

1. Install the tools the agent will reach for: Foundry's `cast` (`brew install foundry`, or see [getfoundry.sh](https://getfoundry.sh)), `curl` and `jq`.
2. Provide a wallet, in one of two forms:
   - A private key in your shell: `export POD_PRIVATE_KEY=...` in the terminal that will start Claude Code. Never paste a key into the chat.
   - A Foundry keystore in `~/.foundry/keystores` (or the folder in `POD_KEYSTORE_DIR`), named with `export POD_KEYSTORE=<name>`. If the folder holds only one keystore, the name is optional. The password goes in the macOS Keychain: `security add-generic-password -s foundry-keystore -a <name> -w`.
3. Check the wallet: `bash .claude/skills/pod/scripts/check-wallet.sh`. It prints the address and which form it found.
4. Start a session in this folder: `claude`. The skill loads from `.claude/skills/pod/` with no install step.

**Disable a globally installed `pod` plugin while testing this branch.** Run `/plugin`, find `pod`, and disable it, then start a new session. Otherwise the session silently gets the plugin's skills as well, and the test no longer shows the raw approach.

### Use the skill elsewhere

Copy it to your personal skills folder, and every Claude Code session on this machine gets it:

```
mkdir -p ~/.claude/skills
cp -R .claude/skills/pod ~/.claude/skills/pod
```

## Example requests

- "What markets are on pod, and which moved most today?"
- "What's our balance and our open positions on pod?"
- "Show the NVDA order book."
- "Buy $20 of NVDA at the current price, then cancel it if it does not fill."

## Architecture, strengths and weaknesses

**Architecture.** One skill and one script. The skill says what pod is, where its endpoints are and where the docs are. The agent reads the docs, then calls the REST API, JSON-RPC and WebSocket channels itself with `curl`, `cast` and whatever else it chooses. It signs and sends transactions with `cast`. The only fixed rules are: pod staging only, and never print, store or commit a private key or password.

**Strengths.**

- Full flexibility. The agent may call any route with any parameter, and can do anything pod's API allows.
- Nothing to maintain. There is no code that encodes pod's rules, so nothing to update when pod changes.
- Always current. The agent reads pod's live docs on each task.

**Weaknesses.**

- Every number conversion is improvised each time. The agent reads pod's formats in the docs and must apply them right, on its own, every time.
- Every transaction is improvised each time: the agent builds it from the docs, and works out on its own whether it really did what was asked.
- Nothing is tested. No conversion or order building has been checked in advance.
- No state, no settings and no status. The agent does not remember the wallet, does not know whether it can trade before it tries, and has no defaults.
- Approval exists nowhere except Claude Code's own permission prompts. Nothing stops a trade except the prompt for the shell command that sends it.
- Results cannot be checked against tested code. When the agent reports a balance or a fill, there is nothing to compare it with.
- Runs differ. The same request can take a different path, a different time and a different number of tokens each time.

## Secrets

Nothing secret belongs in this repo: no private keys, keystores, seed phrases, passwords or `.env` files.

- [`.gitignore`](.gitignore) keeps out key, wallet, environment and credential files.
- [gitleaks](https://github.com/gitleaks/gitleaks) checks every commit with pod-specific rules in [`.gitleaks.toml`](.gitleaks.toml) on top of its defaults. Turn the hook on once per clone:
  ```
  brew install gitleaks
  git config core.hooksPath .githooks
  ```
- Full scan at any time: `gitleaks dir . --config .gitleaks.toml`.
