# Branch 4-cli: the pod command and the approval hook

*Spec, 2026-11-26. Branch `4-cli`. The sections 02 to 07 still hold each section's decisions and findings; this note says how they are delivered here.*

The same functions as the hybrid plugin (`3-plugin`), delivered as a product: one `pod` command that a person, Claude Code or any other shell agent can use, and a thin Claude Code plugin on top. The scripts are the same tested scripts, wrapped behind one entry point, not rewritten.

## Layout

| Path | What it is |
|---|---|
| `cli/pod` | The command. Routes each command to its script, prints the manuals, sets `POD_CLI=1` |
| `cli/libexec/` | The scripts, moved from `plugins/pod/scripts/`. Each starts with its command's manual in `#:` lines |
| `cli/install.sh` | Links `pod` into `~/.local/bin` (or `--bin DIR`); `--uninstall` removes the link |
| `cli/tests/` | `units.sh`, `live-units.mjs`, `smoke.sh`, `live-reconnect.sh`, `contract.sh`, `install.sh` |
| `plugins/pod/skills/` | `pod` (everything said in words), `setup`, `status`, `settings` (started only by the person) |
| `plugins/pod/hooks/` | `hooks.json` and `pod-guard.sh`, the approval hook |
| `plugins/pod/tests/guard.sh` | The hook's unit tests |

## Command map

| Hybrid script | Command |
|---|---|
| `setup.sh --keystore NAME \| --env VAR [--yes \| --skip-test]` | `pod setup --keystore NAME \| --env VAR [--yes \| --skip-test]` |
| `list-wallets.sh` | `pod setup wallets` |
| `profile.sh show` | `pod setup show` |
| `test-transaction.sh [--yes \| --dry-run]` | `pod setup test [--yes \| --dry-run]` |
| `profile.sh delete` | `pod setup disconnect` |
| `check-tools.sh`, `check-network.sh` | `pod setup tools`, `pod setup network` |
| `status.sh [--quick]` | `pod status [--quick]` |
| `profile.sh settings` | `pod settings` (or `pod settings show`) |
| `profile.sh set KEY VALUE` | `pod settings set KEY VALUE` |
| `account.sh VIEW ...` | `pod account VIEW ...` |
| `markets.sh VIEW ...` | `pod markets VIEW ...` |
| `live.sh CHANNEL ... \| list \| stop ID` | `pod live CHANNEL ... \| list \| stop ID` |
| `trade.sh buy\|sell\|close\|edit\|cancel\|cancel-all\|stop-loss\|take-profit\|edit-trigger\|cancel-trigger ...` | `pod trade ...` with the same action (plans only) |
| `trade.sh send PLAN_ID`, `trade.sh follow PLAN_ID` | `pod trade send PLAN_ID`, `pod trade follow PLAN_ID` |
| `wallet.sh address`, `wallet.sh type` | `pod wallet address`, `pod wallet type` |
| `wallet.sh sign-message`, `wallet.sh send`, `profile.sh save`, `profile.sh set-test` | Internal only: not reachable through `pod` |
| | `pod --version`, `pod help [COMMAND]`, `--help` or `-h` anywhere |

## The contract

| Part | Rule |
|---|---|
| Output | One JSON object on stdout (`pod live`: one per line). `ok`; on failure `step`, `error` and usually `fix`, which names a `pod` command. Manuals are plain text |
| Exit codes | 0 ok · 1 failed (the JSON says why) · 2 usage (unknown command or option, or a script run without `pod`) · 3 not sent (the person said no at the terminal question) · 130 interrupted |
| Manual | `pod --help` and `pod COMMAND --help`, printed from the `#:` lines at the top of `cli/pod` and of the command's script. `contract.sh` fails when a script accepts an option its manual does not name |
| Entry point | Every script stops with exit 2 unless `POD_CLI=1`, which `cli/pod` sets. One entry point gives one manual and one text for the hook to watch |
| Version | `pod --version` prints `pod 1.0.0`. The skills require 1.0.0 or later |
| State | Unchanged: `~/.config/pod-plugin`, or `POD_PLUGIN_HOME`. The same wallet setup works on every branch |
| Person at a terminal | With approval `ask`, `pod trade send` (and `--send`) shows the plan and asks `Send it? [y/N]` when stdin and stdout are a terminal. Without a terminal it does not ask |

## The hook

`plugins/pod/hooks/pod-guard.sh`, declared in `hooks/hooks.json` as a `PreToolUse` command hook on `Bash|PowerShell|Monitor|Write|Edit|MultiEdit|NotebookEdit`, with `"onFailure": "block"` so a broken hook blocks rather than lets everything through.

| The tool call would | Approval `ask` | Approval `auto` |
|---|---|---|
| Read or plan (`pod status`, `pod account`, `pod markets`, `pod live`, `pod trade buy ...`) | No opinion | No opinion |
| Send: `pod trade send`, `pod trade ... --send`, `pod setup ... --yes`, `trade.sh`/`wallet.sh` with `send`, `test-transaction.sh --yes`, anything with `POD_CLI` | ask | No opinion |
| Switch approval off: `approval auto` anywhere | ask | ask |
| Touch pod's files (`pod-plugin`, `POD_PLUGIN_HOME`, or a file tool on a path in pod's folder) | ask | ask |
| Use the wallet directly: `cast send`, `cast mktx`, `cast publish`, `eth_sendRawTransaction`, `foundry-keystore`, `.foundry/keystores` | ask | ask |

In permission modes `bypassPermissions` and `dontAsk`, every "ask" above becomes "deny", with a reason that tells Claude nothing was run and the person must run the command or change mode.

**How it reads a command.** It drops quotes and backslashes, turns shell punctuation (`; | & ( ) < > { } \` $ = , :`) into spaces, lower-cases the text and looks at the words: a `trade` (or `trade.sh`) word followed anywhere later by `send` or `--send`; a `setup`, `setup.sh` or `test-transaction.sh` word followed by `--yes`; and so on. So it does not matter where the command sits (pipeline, `&&`, `;`, subshell, `$(...)`, new line), what precedes it (env assignments, `env`, `nohup`, `xargs`), which path names `pod`, or whether it is wrapped in `bash -c '...'` or split with quotes (`p''od`). It errs on the side of asking: `git commit -m "trade send fix"` asks too.

**File tools.** A `Write`, `Edit`, `MultiEdit` or `NotebookEdit` on a path in pod's folder always asks. Elsewhere, the new text is read like a command, so a script that would send asks before it is written; `.md`, `.txt`, `.rst` and `.html` files pass, because prose names commands without running them.

**The question.** For `pod trade send PLAN_ID` the reason names the plan from `plans/PLAN_ID.json`: its summary, value, fee, margin and notes. Claude Code shows it in its permission prompt, labelled `[plugin:pod]`.

**Fail closed.** No `jq`: the hook scans the raw input and still asks or denies. Input that is not JSON: scanned the same way. An unreadable or broken profile counts as approval `ask`.

### What Claude Code's documentation says (read 2026-11-26)

| Question | The docs | Source |
|---|---|---|
| How a plugin declares hooks | `hooks/hooks.json` at the plugin root, same shape as the `hooks` object in settings; `${CLAUDE_PLUGIN_ROOT}` is the plugin's folder. Registered when the session loads the plugin, not when a skill runs | [plugins/components#hooks](https://code.claude.com/docs/en/plugins/components#hooks), [hooks#plugin-scripts](https://code.claude.com/docs/en/hooks) |
| Same-name plugins | "When another enabled plugin has the same name, one of the two registers its hooks/hooks.json hooks and the other's are left out" | [plugins/components#hooks](https://code.claude.com/docs/en/plugins/components#hooks) |
| PreToolUse input | Common fields including `permission_mode` (`"default"`, `"plan"`, `"acceptEdits"`, `"auto"`, `"dontAsk"`, `"bypassPermissions"`; Manual arrives as `"default"`), plus `tool_name`, `tool_input` (`command` for Bash), `tool_use_id` | [hooks#common-input-fields](https://code.claude.com/docs/en/hooks), [hooks#pretooluse](https://code.claude.com/docs/en/hooks) |
| Output for "ask" | `{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "ask", "permissionDecisionReason": "..."}}`. "`ask` prompts the user to confirm"; the reason "is shown to the user in the permission prompt". Precedence across hooks: deny > defer > ask > allow | [hooks#pretooluse-decision-control](https://code.claude.com/docs/en/hooks) |
| Bash matcher | Also runs on commands started with the Monitor tool ("its allow and updatedInput have no effect on them") | [hooks#match-monitor-commands](https://code.claude.com/docs/en/hooks) |
| Hook failure | Fails open by default; `"onFailure": "block"` blocks instead (v2.1.295 or later) | [hooks#block-the-action-when-a-hook-fails](https://code.claude.com/docs/en/hooks) |
| default, acceptEdits, plan | "ask" sends the call to the permission prompt. acceptEdits only auto-approves file edits and `mkdir`, `touch`, `rm`, `rmdir`, `mv`, `cp`, `sed` | [permission-modes](https://code.claude.com/docs/en/permission-modes) |
| auto | "a PreToolUse hook's `"ask"` normally sends the tool call to the permission prompt, and the classifier doesn't decide it", with two exceptions (calls Claude Code's own checks also flag, where the classifier can deny first; `SubagentHandback`) | [hooks#pretooluse-decision-control](https://code.claude.com/docs/en/hooks); [permission-modes](https://code.claude.com/docs/en/permission-modes): "auto mode still shows you those prompts" |
| dontAsk | "Auto-denies every call that would otherwise prompt" | [permissions#permission-modes](https://code.claude.com/docs/en/permissions) |
| bypassPermissions | "disables permission prompts and safety checks so tool calls execute immediately", except "actions no mode auto-approves". That list names explicit ask rules, connector tools set to ask, AskUserQuestion and MCP tools that require interaction, critical `rm` paths, and others. **A hook's "ask" is not in the list.** The docs do not say whether a hook's "ask" still prompts in this mode | [permission-modes#skip-all-checks-with-bypasspermissions-mode](https://code.claude.com/docs/en/permission-modes), [#actions-no-mode-auto-approves](https://code.claude.com/docs/en/permission-modes) |
| Headless `-p` | "Calls needing approval are denied unless you approve them with an allow rule, hook, canUseTool callback, or --permission-prompt-tool". For "ask": "When Claude Code denies the call in a -p run where no one can answer that prompt, Claude reads the reason in the tool result instead" | [permission-modes](https://code.claude.com/docs/en/permission-modes), [hooks#pretooluse-decision-control](https://code.claude.com/docs/en/hooks) |
| Allow rules against a hook | "Deny and ask rules are still evaluated regardless of what the hook returns". The docs do not say in so many words that an allow rule cannot override a hook's "ask" | [permissions#precedence-among-rules-hooks-and-mods](https://code.claude.com/docs/en/permissions) |
| Mods | Without managed settings, a Team or Enterprise login or `managed-mcp.json`, an installed mod handling `tool.check` "can skip the prompt from ... a PreToolUse hook" | [permissions#precedence-among-rules-hooks-and-mods](https://code.claude.com/docs/en/permissions) |
| Plugin `bin/` | "Files in `bin/` at the plugin root are on the PATH of the Bash tool's shell while the plugin is enabled". Not installed by claude.ai or Cowork | [plugins/components#executables](https://code.claude.com/docs/en/plugins/components), [plugins-reference](https://code.claude.com/docs/en/plugins-reference) |
| `disable-model-invocation` | "Set to true to prevent Claude from automatically loading this skill" | [skills#frontmatter-reference](https://code.claude.com/docs/en/skills) |

### What we measured (Claude Code 2.1.332, headless `-p`, claude-haiku)

A probe hook that answers "ask" for a harmless `echo`, one run per mode: the command was **denied, not run, in every mode**: default, default with an allow rule `Bash(echo *)`, acceptEdits, auto, dontAsk (with the allow rule) and bypassPermissions. So in `-p` a hook's "ask" is not skipped by bypassPermissions and is not overridden by an allow rule. Interactive bypassPermissions could not be tested from here.

The same with `pod-guard.sh` itself, loaded through `--settings`, `--allowedTools "Bash(pod *)"`, and a fake `pod` on PATH that only records its arguments (so nothing could reach pod):

| Command | Mode | Approval | Fake pod ran? |
|---|---|---|---|
| `pod markets list nvda` | default | ask | yes |
| `pod trade send p1234abcd` | default | ask | no: denied (the "ask" has nobody to answer in `-p`) |
| `pod trade send p1234abcd` | auto | ask | no: denied |
| `pod trade send p1234abcd` | bypassPermissions | ask | no: the hook's deny ("this session cannot ask you") |
| `bash -c 'pod trade send p1234abcd'` (with `Bash(bash *)` allowed) | bypassPermissions | ask | no: the hook's deny |
| `pod settings set approval auto` | bypassPermissions | ask | no: the hook's deny |
| `pod markets` | bypassPermissions | ask | yes |
| `pod trade send p1234abcd` | default | auto | yes |

Not measured: the interactive prompt itself (it needs a person), and the hook loaded from the installed plugin rather than `--settings` (an installed `pod` plugin from another branch shares the name; see "Same-name plugins").

### Decisions

| # | Question | Decision |
|---|---|---|
| H1 | bypassPermissions, where the docs do not promise a prompt | **Deny.** `permission_mode` tells the hook the mode, so it never relies on a prompt it cannot see |
| H2 | dontAsk | **Deny**, with a reason; Claude Code would deny the "ask" anyway |
| H3 | Headless `-p` | Arrives as `default`, so the hook answers "ask"; Claude Code turns it into a denial, unless a `--permission-prompt-tool` or SDK `canUseTool` callback answers, in which case that host is the approver |
| H4 | Two questions per trade in Claude Code (the skill's AskUserQuestion, then the permission prompt) | **Kept.** The first is the conversation with the full preview; the second is the gate the agent cannot skip. The hook's reason repeats the plan so the second is quick |
| H5 | The setup test transaction | Guarded like a trade: it sends two real transactions |
| H6 | Direct scripts | Refuse without `POD_CLI=1`, and the hook asks on `POD_CLI`, on `trade.sh`/`wallet.sh` with `send`, and on `test-transaction.sh --yes` |
| H7 | A plugin `bin/pod` | Not used: the CLI must stand alone, and the plugin ships no code for pod's functions |

### What still gets around it

The hook guards the product's send path, not the wallet.

- **Obfuscated text**: `echo cG9kIHRyYWRlIHNlbmQ= | base64 -d | sh`, `eval` of built strings, a script written in one step under an innocent name with no pod words in it (for example a Python file that assembles the words at run time), or a program in another language that calls the scripts.
- **Its own transaction**: an agent that writes its own signing code (`cast` under another name, a Node or Python library) and posts to pod's RPC with `curl`, reading the key from a place the hook does not name. The hook catches the obvious forms (`cast send`, `eth_sendRawTransaction`, the Keychain service name), not every form.
- **Outside Claude Code**: the hook exists only in Claude Code. Another agent harness, or Claude Code without the plugin, gets no prompt; the CLI's terminal question needs a terminal.
- **Mods**: an installed mod that approves `tool.check` can skip a hook's prompt on setups without managed settings (see the docs row above).
- **A `-p` host**: a `--permission-prompt-tool` or SDK `canUseTool` that approves automatically.

The portable next step, not built here: a confirmation that the CLI opens **outside the agent's reach**, such as a macOS dialog or Touch ID before signing, so the person approves on the machine whatever harness runs the agent.
