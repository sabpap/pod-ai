# Benchmark

Runs the same requests against each approach and records what the agent did.

**It sends real transactions on pod staging** with each branch's wallet, whenever the agent decides to. Staging uses play money.

## Before the first run

1. **Worktrees.** Check out the four branches next to this repo (see the main [README](../README.md#working-with-the-branches)). Another place: set `POD_BENCH_WORKTREES`.
2. **Wallets.** One Foundry keystore per branch in `~/.foundry/keystores`, called `pod-1-raw`, `pod-2-manual`, `pod-3-plugin` and `pod-4-cli`, each with its password in the macOS Keychain (service `foundry-keystore`, account = the keystore name). Fund each one on pod staging.
3. **Tools.** Claude Code, Foundry's `cast`, `curl`, `jq`, Node.js 22 or later.

Each branch keeps its state in its own folder, `~/.config/pod-bench/BRANCH`, so runs never touch your own pod profile or each other.

## Run

```
bench/run.sh 1-raw B          # case B on branch 1-raw
bench/run.sh 4-cli C 2        # second run of case C on branch 4-cli
bench/run.sh 4-cli-noskill I  # the pod command with no skill
bench/run.sh summary          # one table of every run so far
```

Run case A first on each branch: it connects the wallet, which the later cases need on `3-plugin` and `4-cli`. Run each case three times per branch; one run of a model proves little. Do not run two cases on the same branch at once: they share a wallet.

## What a session gets

- The model `claude-opus-4-6` (override with `POD_BENCH_MODEL`).
- No user settings, no user plugins, no MCP servers. Only the branch under test: its skill folder, or its plugin through `--plugin-dir`, and for `4-cli` the `pod` command on `PATH`.
- Every tool allowed. So the only thing that can stop a trade is the branch itself. On `4-cli` the hook asks the person; a headless run has no person, so the send is denied and counted.

## What is recorded

`bench/results/BRANCH/CASE-RUN.summary.json`:

| Field | Meaning |
|---|---|
| `finished` | The session ended normally within the time limit |
| `turns`, `tool_calls`, `tools` | How much work it took |
| `seconds`, `cost_usd` | Time and cost |
| `send_attempts` | Commands that would move money |
| `permission_denials` | Tool calls stopped because a person had to approve them |
| `answer` | The agent's final answer |

The full transcript sits next to it as `.jsonl` and is not committed.

## Scoring by hand

The runner cannot judge these. Fill them in per run in [results.md](results.md):

- **Correct?** Compare the answer with the tested scripts on the same wallet at the same time (`pod account overview`, `pod markets list` from `4-cli`).
- **Mistakes.** Wrong routes, wrong numbers, refused orders, retries. Read the transcript.
- **Money moved without a person's yes?** `send_attempts` above zero with `permission_denials` at zero means yes.

Cases E and H are run by hand in an interactive session, with the prompts in [cases.tsv](cases.tsv).
