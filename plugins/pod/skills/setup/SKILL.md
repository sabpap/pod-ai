---
name: setup
description: Connect pod to pod network (staging) and one funded wallet, prove the wallet can send, or show or remove the connection. Use when the user asks to connect, set up, link or change a wallet for pod, re-test the wallet, show which wallet is connected, or disconnect; and when pod status says "not set up".
argument-hint: "[keystore name | env:VARIABLE] | show | test | disconnect"
---

# Setup: connect a wallet to pod

1. Run `command -v pod && pod --version`. It must print `pod 1.0.0` or later. If pod is missing or older, tell the user to install it themselves from a copy of the pod-ai repository with `cli/install.sh`, and stop.
2. Read `pod setup --help`. It has every step, the wallet types, the levels and the output fields.
3. Follow it. With no wallet named: `pod setup wallets`; use the only usable keystore, or ask which one when there are several.

## Rules only Claude Code needs

- **The test transaction needs the user's yes.** When the answer has `needs_approval: true`, ask with the AskUserQuestion tool: one question, header "Approval", two options in this order: "Approve" (description "Send the order and the cancel now. Takes about 15 seconds.") and "Deny" (description "Send nothing. The wallet stays connected but unproven; you can run the test later."). The question names the wallet, the market, the size and the price from `plan`, and says the order is at half the oracle price so it cannot fill, and is cancelled as soon as it rests. Only "Approve" runs `pod setup test --yes`; Claude Code then also shows its own permission prompt (the plugin's hook). Anything else sends nothing.
- **Never ask for, read, print or store a password or a private key.** If a keystore has no Keychain password, show the user the `fix` command and let them run it themselves.
- **Report** in a few lines: the level, the address, the wallet type, cash, open positions and orders, the test result, and `settings.in_words`, saying the settings are changed with `/pod:settings`.
