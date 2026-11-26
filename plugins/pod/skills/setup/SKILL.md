---
name: setup
description: Connect the pod plugin to pod network (staging) and one funded wallet, prove the wallet can really send transactions, or show or remove the connection. Use when the user asks to connect, set up, log in, link or change a wallet for pod, re-test the wallet, show which wallet is connected, or disconnect; and before any pod action when no wallet is connected.
argument-hint: "[keystore name | env:VARIABLE] [--yes] | show | test | disconnect"
---

# Setup: connect a wallet to pod

Setup connects this plugin to **pod staging** (chain id 129302) and **one wallet**, and saves the result as the profile the rest of the plugin reads. The plugin only ever sends on pod staging.

All scripts are in `${CLAUDE_PLUGIN_ROOT}/scripts/`. Each prints one JSON object. `"ok": false` always comes with `step`, `error` and usually `fix`: tell the user the error and the fix in plain words, and stop.

## Wallet types

| Type | What it is | How to name it |
|---|---|---|
| Keystore | An encrypted Foundry keystore in `~/.foundry/keystores`, whose password is in the macOS Keychain (service `foundry-keystore`, account = keystore name) | `--keystore NAME` |
| Environment variable | A private key held in an environment variable of this session, for servers and CI | `--env VARIABLE` (default `POD_PRIVATE_KEY`) |

Never ask for, read, print or store a password or a private key. If a keystore has no Keychain password, show the user the `fix` command and let them run it themselves.

## Connect a wallet

1. **Find the wallet**, unless the user or the arguments already name it:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/list-wallets.sh"
   ```
   It lists keystores and whether each has a Keychain password. `address` is often null: Foundry keystores do not store it in clear. If there is exactly one usable keystore and the user did not ask for something else, use it. If several, ask which one. If none, offer the environment-variable route.

2. **Run setup**:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" --keystore NAME
   "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" --env POD_PRIVATE_KEY
   ```
   It checks the tools (`cast`, `jq`, `curl`, `bc`; Node.js 22 or later is needed only for live updates, and `live_updates` in the tools check says whether it is there), checks pod answers and is open for writes, reads the address, signs a test message and verifies it, reads the account, and saves the profile.

3. **Read the answer's `level`**:

   | `level` | Meaning | What to do |
   |---|---|---|
   | `connected, untested` with `needs_approval: true` | Connected and funded; the test transaction is waiting for approval | Step 4 |
   | `connected, untested` without `needs_approval` | Connected and funded; the test was skipped. Trading works but is unproven | Tell the user; offer the test |
   | `connected, read-only` | Connected, but the account has no cash on pod, so it cannot trade | Tell the user; nothing else to do until it is funded |
   | `ready to trade` | Everything passed, including the test transaction | Report it |
   | `problem` | The test transaction failed | Report `test_transaction.error` and `note` |

4. **Get approval for the test transaction.** Ask with the AskUserQuestion tool: one question, two options, nothing else. Fill it from the `plan`:

   - **question:** "Approve a test transaction from wallet `<wallet>` on pod staging? It places a maker-only buy of `<size>` `<market>` at $`<price_usd>` (half the oracle price of $`<oracle_price_usd>`, so it cannot fill), then cancels it as soon as it rests in the book. This proves the wallet can trade."
   - **header:** "Approval"
   - **options**, in this order:
     1. label "Approve", description "Send the order and the cancel now. Takes about 15 seconds."
     2. label "Deny", description "Send nothing. The wallet stays connected but unproven; you can run the test later."

   Do not add a recommendation or a third option. If the AskUserQuestion tool is not available, ask the same question in plain text and accept only "approve" or "deny".

   **Only "Approve" sends.** Any other answer, including a typed "Other" reply, counts as Deny: send nothing and report "connected, untested: test transaction not approved. Trading is allowed; the first trade will be the proof".

   On Approve:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/test-transaction.sh" --yes
   ```
   On success, the wallet is **ready to trade**.

   **Autonomous agents** with no user to ask may pass `--yes` straight to `setup.sh` only when their instructions allow sending transactions.

5. **Report** in a few lines: the level, the address, the wallet type, cash, open positions and orders, the test result with its two transaction hashes, and the trading settings from `settings.in_words` (e.g. "asks before every trade · market orders within 2% of the price · limit orders rest 1 day"), saying they can be changed with `/pod:settings`.

## Other actions

| User asks | Run |
|---|---|
| "Which wallet is connected?" | `profile.sh show` |
| "Test my wallet again" | `test-transaction.sh` (plan), the Approve / Deny question from step 4, then `test-transaction.sh --yes` only on Approve |
| "Disconnect" | `profile.sh delete`. It deletes only the profile, never the keystore, the Keychain entry or the variable |
| "Use another wallet" | `profile.sh delete`, then connect again. One wallet at a time |
| "What are my settings?" / "stop asking me" | Show them with `profile.sh settings`; the user changes them by typing `/pod:settings` (switching to `auto` is always the user's own action) |

## Facts to keep straight

- The profile is `~/.config/pod-plugin/profile.json` (only the user can read it). It holds the network, the wallet type, the keystore or variable name and the address. Never a secret.
- Pod's fees are paid from the account's pod cash, so an account with zero cash cannot send anything.
- The test order expires by itself 5 minutes after its deadline, so a failed cancel leaves nothing behind for long.
- Pod error `-32025` means "not available in your region": the wallet cannot trade from here, whatever else passes.
- Pod staging is a test network with play money; it is reset from time to time, which wipes balances. After a reset, run the test again.
