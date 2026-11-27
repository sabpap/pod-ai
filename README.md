# pod-ai, branch 4-cli: pod as a command

This branch gives an agent pod network (staging testnet) as a **product**: one `pod` command that a person, Claude Code or any other shell agent can use, and a thin Claude Code plugin on top. The command holds everything that is true and done: the profile, the settings, plans, signing, and a manual in `--help`. The plugin holds how the agent and the person meet in Claude Code: four short skills, and a hook that makes Claude Code ask the person before any send.

The other approaches are in branches `1-raw`, `2-manual` and `3-plugin`, and are compared on `main`.

- The command: [cli/](cli/) (`pod`, `libexec/`, `install.sh`, `tests/`)
- The plugin: [plugins/pod/](plugins/pod/) (`skills/`, `hooks/`, `tests/`)
- Specs: [specs/08-cli-and-hook.md](specs/08-cli-and-hook.md) (command map and hook design); sections 02 to 07 hold each section's decisions

## Setup

From cloning this branch to a wallet that is ready to trade. You do steps 1 to 4 and step 6; Claude does step 5.

**You need:** a Mac and [Claude Code](https://code.claude.com).

On Linux, the keystore wallet in step 3 does not work: pod reads its password from the macOS Keychain. Use a private key in an environment variable instead (`pod setup --env POD_PRIVATE_KEY`).

### 1. Clone the CLI branch

```
git clone -b 4-cli https://github.com/sabpap/pod-ai.git ~/pod-ai-cli
```

### 2. Install Foundry

Install [Foundry](https://getfoundry.sh) by following the steps on its site. It provides `cast`, which pod uses for the wallet.

### 3. Choose a wallet

Run these in your own terminal. You type the key and the password yourself, and Claude never sees them.

**Option A: create a new wallet and fund it**

```
cast wallet new ~/.foundry/keystores pod-ai-stg-wallet
security add-generic-password -s foundry-keystore -a pod-ai-stg-wallet -w
```

The first command asks for a password and creates the wallet. The second stores the same password in the macOS Keychain, so pod can sign without asking you each time. Then fund the wallet on pod staging. If the first command did not print the address, setup shows it in step 5.

**Option B: use a wallet you already have, with funds on pod staging**

If it is already a Foundry keystore, only store its password:

```
security add-generic-password -s foundry-keystore -a YOUR_KEYSTORE_NAME -w
```

If you only have the private key, import it, then store the password:

```
cast wallet import pod-ai-stg-wallet --interactive
security add-generic-password -s foundry-keystore -a pod-ai-stg-wallet -w
```

### 4. Add the plugin to Claude Code

In Claude Code:

```
/plugin marketplace add ~/pod-ai-cli
/plugin install pod@pod-ai
```

Then quit and start a new Claude Code session: skills and hooks load only when a session starts.

If you already have another `pod` plugin installed, for example from branch `3-plugin`, disable it with `/plugin`. Only one pod plugin's hooks load at a time.

### 5. Let Claude do the rest

In the new session, say:

> Install the pod command from ~/pod-ai-cli with anything it needs, then set up pod with the pod-ai-stg-wallet wallet.

Use your own keystore name if you kept an existing one in Option B. Claude will:

- run `cli/install.sh`, which links `pod` into `~/.local/bin`;
- install `jq` and Node.js 22 or later if they are missing, and add `~/.local/bin` to your PATH if needed;
- run `pod setup --keystore pod-ai-stg-wallet`, which checks the tools, checks that pod staging is reachable, signs a test message and reads your balance.

### 6. Approve the test transaction

Claude Code asks you, in a prompt labelled `[plugin:pod]`, before setup sends a test order. The order is placed at half the market price so it cannot fill, and it is cancelled straight away: two transactions, about 15 seconds. Approve it.

### Check the result

Setup ends with one of these levels:

| Level | Meaning | What to do |
|---|---|---|
| ready to trade | Everything passed | Nothing. Try "what's my balance?" |
| connected, read-only | The wallet has no cash on pod | Fund it, then ask Claude to run the wallet test again |
| connected, untested | You skipped or denied the test | Ask Claude to test the wallet again |
| problem | The test order failed | Claude shows the error and the command that fixes it |

### Good to know

- **Trades always ask first.** The approval setting starts at "ask", and Claude Code asks you before every send. Switching approval off with `/pod:settings` also asks.
- **You can use pod without Claude.** In a terminal, `pod --help` lists every command, for example `pod status` or `pod markets movers`.
- **Fewer prompts for reading.** To let Claude read and plan without asking each time, add these rules to `.claude/settings.json`. Sends still ask.
  ```json
  { "permissions": { "allow": ["Bash(pod status *)", "Bash(pod markets *)", "Bash(pod account *)", "Bash(pod live *)", "Bash(pod trade *)"] } }
  ```
- **Uninstall.** Run `~/pod-ai-cli/cli/install.sh --uninstall`, then remove the plugin with `/plugin`. Your wallet and profile (`~/.config/pod-plugin`) stay.
- **A wallet connected on another branch works here unchanged.** All branches share the same profile.

## Three things this branch can do that `3-plugin` cannot

### 1. A person uses pod in a plain terminal

No Claude Code needed:

```
pod status
pod markets movers
pod markets market NVDA | jq -r .data.summary
pod trade buy NVDA --usd 10 --market     # plans only; prints plan_id
pod trade send PLAN_ID                   # with approval "ask" it shows the plan and asks: Send it? [y/N]
```

A "no" sends nothing and exits with code 3.

### 2. An agent with no pod skill works from `pod --help` alone

The manual is the help. A session with the Skill tool turned off and only `Bash(pod *)` allowed answered a read and planned a trade (tested 2026-11-26 with claude-opus-4-6: 5 turns for the read, 4 for the plan):

```
claude -p "Use the pod command (run pod --help first; it is the only documentation). What markets are on pod? List the five most traded with their prices." \
  --model claude-opus-4-6 --allowedTools "Bash(pod *)" --disallowedTools Skill
claude -p "Use the pod command (run pod --help first; it is the only documentation). Plan, but do not send, a buy of 10 dollars of NVDA at market on pod." \
  --model claude-opus-4-6 --allowedTools "Bash(pod *)" --disallowedTools Skill "Bash(pod trade send *)"
```

The same works for any agent harness that can run a shell command.

### 3. Simple permission rules, with every send still guarded

Because every pod action is one command with a stable shape, a few rules remove the routine prompts. In `.claude/settings.json` (or your user settings):

```json
{
  "permissions": {
    "allow": [
      "Bash(pod status *)",
      "Bash(pod markets *)",
      "Bash(pod account *)",
      "Bash(pod live *)",
      "Bash(pod trade *)"
    ]
  }
}
```

Reading and planning now run without a prompt. Sending still asks: the plugin's hook answers "ask" for `pod trade send` while the approval setting is "ask", and an allow rule does not override it (measured in headless runs: a hook's "ask" was not skipped by a matching allow rule). Try it: ask the agent to buy $10 of NVDA. It plans without a prompt, tells you the plan, and runs the send; Claude Code then asks you once, in its permission prompt labelled `[plugin:pod]`, with the plan's summary, value, fee, margin and every note. Deny it and nothing is sent.

## The approval hook

`plugins/pod/hooks/pod-guard.sh` runs before every Bash, PowerShell, Monitor and file-tool call. It makes Claude Code ask the person when the call would:

- **send** (`pod trade send`, `pod trade ... --send`, `pod setup ... --yes`) while the approval setting is "ask";
- **switch approval off** (`pod settings set approval auto`), always;
- touch **pod's own files** or the **wallet directly** (`cast send`, `eth_sendRawTransaction`, the Keychain password), always.

Reading and planning pass untouched. It finds a send wherever it sits: in a pipeline, after `&&` or `;`, behind env assignments, through an absolute path to `pod`, inside `bash -c "..."`, split by quotes, through a variable, alias or function standing for `pod`, or through the scripts behind `pod` (which also refuse to run without `pod`). A script file that would send asks before it is written.

**One question per send.** The agent tells you the plan, then runs the send; Claude Code's prompt is the only question. For a trade it reads, for example: "pod: Send this trade from your pod wallet? buy 0.066361 NVDA perp at market, no worse than $153.7. Value about $9.99 at the current price, at most $10.19 at the worst price. Fee $0.0045. Margin $0.51, free margin after $95.2. Note: size 0.066361 = $10 at $150.69 (the current price). … (plan p…) Approve to send it; deny and nothing is sent." If you deny it, the agent says nothing was sent and stops. With the approval setting "auto", trades go through without a question; switching to "auto" always asks.

**Permission modes.** In default, acceptEdits, plan and auto modes, Claude Code shows its prompt (auto mode's classifier does not decide a hook's "ask"). In `dontAsk` and `bypassPermissions`, the hook answers **deny**: the docs do not promise that bypassPermissions shows a hook's question, so nothing is sent unasked. In headless `claude -p`, nobody can answer, so Claude Code denies the call. Sources and measurements: [specs/08-cli-and-hook.md](specs/08-cli-and-hook.md).

**What still gets around it.** The hook guards the product's send path, not the wallet. An agent can still hide a send from a text check (`base64 -d | sh`, `eval`, a program that assembles the command at run time, or `pod` read from a file through `xargs`), or write its own signing and `curl` code that the hook does not recognise. An installed Claude Code mod can approve past a hook on setups without managed settings. And outside Claude Code there is no hook at all. The portable next step, not built here: a confirmation the CLI opens **outside the agent's reach**, such as a macOS dialog or Touch ID before signing.

## Architecture, strengths and weaknesses

| Lives in | What | Holds |
|---|---|---|
| **The CLI** (`cli/`) | What is true and what is done | Profile, settings, plans, signing, sending, the manual (`--help`), the JSON contract and exit codes |
| **The plugin** (`plugins/pod/`) | How the agent and the person meet in Claude Code | Skills: `use` (`/pod:use`), `setup`, `status`, `settings` (person only); the approval hook |

Expected to score about the same as `3-plugin` on agent efficiency: the agent runs the same tested scripts and reads about the same reference, from `--help` instead of a skill.

**Gains**
- **Approval is enforced**, not suggested: Claude Code itself asks before a send, whatever the agent decides, and switching approval off always asks.
- **Use outside Claude Code**: a person in a terminal, or any shell agent, with the same commands and the same profile.
- **A manual that cannot drift**: each command's help sits at the top of the script that implements it, and a test fails when a script accepts an option its manual does not name.
- **A versioned contract**: JSON on stdout, documented exit codes, `pod --version`; the skills require 1.1.0 or later.
- **A base for an MCP server later**: each command is already one call with JSON out.

**Costs**
- **A second thing to install and version.** The plugin does nothing without the command.
- **Skill and CLI can be at different versions.** The skills check `pod --version`, but only for a minimum.
- **The hook only works in Claude Code.** Other harnesses rely on the agent asking, or on a person at a terminal.
- **The question lives in Claude Code's permission prompt.** It is the only approval question, and it cannot be skipped by the agent, but it is a plain-text prompt rather than a designed question with options.
- **The hook errs on the side of asking.** A command that names pod and reads like a send asks, even in a commit message (`git commit -m "pod trade send fix"`), and so do edits to pod's own scripts while the plugin is enabled. Words alone, such as `git commit -m "trade send fix"`, pass.

## Tests

| Test | What it checks | Network |
|---|---|---|
| `cli/tests/units.sh` | Pod's number formats in Bash and jq; time windows; which refused sends last | None |
| `node cli/tests/live-units.mjs` | The live listener's decoding and conditions | None |
| `cli/tests/contract.sh` | Every manual prints and exits 0 at every level; every option a script accepts is in its manual; scripts refuse to run without `pod`; no message names a skill or a script; exit codes | None |
| `cli/tests/install.sh` | Install, run through the link, uninstall, in a temp bin folder | None |
| `plugins/pod/tests/guard.sh` | The hook's decision for each kind of command, each permission mode, approval ask and auto, file tools, and without jq | None |
| `cli/tests/smoke.sh` | Setup, status, account, markets, trading plans and live through `pod`, with a throwaway key and profile; exit codes; the terminal question (a "no" sends nothing; a "yes" goes on, stopped by a closed RPC port) | Pod staging, read-only |
| `cli/tests/live-reconnect.sh` | The listener against a fake pod server that drops the connection: no gap, no repeat. Needs Deno | Local fake, plus staging's market list |
| `pod setup test --yes` | A real order and cancel with the connected wallet | Pod staging, sends two transactions |

Run the smoke test with `POD_KEYSTORE_DIR` pointing at an empty folder to keep it away from your keystores and the Keychain.

## Secrets

Nothing secret belongs in this repo: no private keys, keystores, seed phrases, passwords or `.env` files.

- [`.gitignore`](.gitignore) keeps out key, wallet, environment and credential files, and pod's own profile and temp files.
- [gitleaks](https://github.com/gitleaks/gitleaks) checks every commit with pod-specific rules in [`.gitleaks.toml`](.gitleaks.toml). Turn the hook on once per clone:
  ```
  brew install gitleaks
  git config core.hooksPath .githooks
  ```
- Full scan at any time: `gitleaks dir . --config .gitleaks.toml`.
