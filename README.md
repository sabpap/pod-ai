# pod-ai, branch 4-cli: pod as a command

This branch gives an agent pod network (staging testnet) as a **product**: one `pod` command that a person, Claude Code or any other shell agent can use, and a thin Claude Code plugin on top. The command holds everything that is true and done: the profile, the settings, plans, signing, and a manual in `--help`. The plugin holds how the agent and the person meet in Claude Code: four short skills, and a hook that makes Claude Code ask the person before any send.

The other approaches are in branches `1-raw`, `2-manual` and `3-plugin`, and are compared on `main`.

- The command: [cli/](cli/) (`pod`, `libexec/`, `install.sh`, `tests/`)
- The plugin: [plugins/pod/](plugins/pod/) (`skills/`, `hooks/`, `tests/`)
- Specs: [specs/08-cli-and-hook.md](specs/08-cli-and-hook.md) (command map and hook design); sections 02 to 07 hold each section's decisions

## Setup

1. **Install the command.** From this folder:
   ```
   cli/install.sh                 # links pod into ~/.local/bin (or: cli/install.sh --bin DIR)
   pod --version                  # pod 1.0.0
   ```
   `~/.local/bin` must be on your PATH; the installer says so if it is not. pod needs `cast` (Foundry), `jq`, `curl` and `bc`; `pod live` also needs Node.js 22 or later. `cli/install.sh --uninstall` removes the link.
2. **Add the plugin** (a person does this; Claude Code's auto mode blocks an agent from installing plugins):
   ```
   /plugin marketplace add /path/to/pod-ai
   /plugin install pod@pod-ai
   ```
   Then start a new Claude Code session: skills and hooks load when a session starts.
   **Only one pod plugin at a time.** When two enabled plugins share a name, Claude Code registers the hooks of only one of them. Disable any other installed `pod` plugin (for example one from branch `3-plugin`) with `/plugin` before you test this one.
3. **Connect a wallet**: `pod setup wallets`, then `pod setup --keystore NAME`, or ask the agent to set up pod. The profile stays where it was (`~/.config/pod-plugin`, or `POD_PLUGIN_HOME`), so a wallet connected on another branch works here unchanged.

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

Reading and planning now run without a prompt. Sending still asks: the plugin's hook answers "ask" for `pod trade send` while the approval setting is "ask", and an allow rule does not override it (measured in headless runs: a hook's "ask" was not skipped by a matching allow rule). Try it: ask the agent to buy $10 of NVDA. It plans without a prompt, asks you with its own question, and then Claude Code shows its permission prompt, labelled `[plugin:pod]`, with the plan's summary, value, fee and margin.

## The approval hook

`plugins/pod/hooks/pod-guard.sh` runs before every Bash, PowerShell, Monitor and file-tool call. It makes Claude Code ask the person when the call would:

- **send** (`pod trade send`, `pod trade ... --send`, `pod setup ... --yes`) while the approval setting is "ask";
- **switch approval off** (`pod settings set approval auto`), always;
- touch **pod's own files** or the **wallet directly** (`cast send`, `eth_sendRawTransaction`, the Keychain password), always.

Reading and planning pass untouched. It finds a send wherever it sits: in a pipeline, after `&&` or `;`, behind env assignments, through an absolute path to `pod`, inside `bash -c "..."`, split by quotes, or through the scripts behind `pod` (which also refuse to run without `pod`). A script file that would send asks before it is written.

**Permission modes.** In default, acceptEdits, plan and auto modes, Claude Code shows its prompt (auto mode's classifier does not decide a hook's "ask"). In `dontAsk` and `bypassPermissions`, the hook answers **deny**: the docs do not promise that bypassPermissions shows a hook's question, so nothing is sent unasked. In headless `claude -p`, nobody can answer, so Claude Code denies the call. Sources and measurements: [specs/08-cli-and-hook.md](specs/08-cli-and-hook.md).

**What still gets around it.** The hook guards the product's send path, not the wallet. An agent can still hide a send from a text check (`base64 -d | sh`, `eval`, a program that assembles the command at run time), or write its own signing and `curl` code that the hook does not recognise. An installed Claude Code mod can approve past a hook on setups without managed settings. And outside Claude Code there is no hook at all. The portable next step, not built here: a confirmation the CLI opens **outside the agent's reach**, such as a macOS dialog or Touch ID before signing.

## Architecture, strengths and weaknesses

| Lives in | What | Holds |
|---|---|---|
| **The CLI** (`cli/`) | What is true and what is done | Profile, settings, plans, signing, sending, the manual (`--help`), the JSON contract and exit codes |
| **The plugin** (`plugins/pod/`) | How the agent and the person meet in Claude Code | Skills: `pod`, `setup`, `status`, `settings` (person only); the approval hook |

Expected to score about the same as `3-plugin` on agent efficiency: the agent runs the same tested scripts and reads about the same reference, from `--help` instead of a skill.

**Gains**
- **Approval is enforced**, not suggested: Claude Code itself asks before a send, whatever the agent decides, and switching approval off always asks.
- **Use outside Claude Code**: a person in a terminal, or any shell agent, with the same commands and the same profile.
- **A manual that cannot drift**: each command's help sits at the top of the script that implements it, and a test fails when a script accepts an option its manual does not name.
- **A versioned contract**: JSON on stdout, documented exit codes, `pod --version`; the skills require 1.0.0 or later.
- **A base for an MCP server later**: each command is already one call with JSON out.

**Costs**
- **A second thing to install and version.** The plugin does nothing without the command.
- **Skill and CLI can be at different versions.** The skills check `pod --version`, but only for a minimum.
- **The hook only works in Claude Code.** Other harnesses rely on the agent asking, or on a person at a terminal.
- **Two questions per trade in Claude Code**: the skill's Approve / Deny question, then Claude Code's permission prompt.
- **The hook errs on the side of asking.** Any command whose words read like a send (for example `git commit -m "trade send fix"`) asks too, and so do edits to pod's own scripts while the plugin is enabled.

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
