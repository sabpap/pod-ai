---
name: setup
description: Connect pod to pod network (staging) and one funded wallet, prove the wallet can send, or show or remove the connection. Use when the user asks to connect, set up, link or change a wallet for pod, re-test the wallet, show which wallet is connected, or disconnect; and when pod status says "not set up".
argument-hint: "[keystore name | env:VARIABLE] | show | test | disconnect"
---

# Setup: connect a wallet to pod

1. Run `command -v pod && pod --version`. It must print `pod 1.1.0` or later. If pod is missing or older, tell the user to install it themselves from a copy of the pod-ai repository with `cli/install.sh`, and stop.
2. Read `pod setup --help`. It has every step, the wallet types, the levels and the output fields.
3. Follow it. With no wallet named: `pod setup wallets`; use the only usable keystore, or ask which one when there are several.

## Rules only Claude Code needs

- **The test transaction needs the user's yes, and Claude Code asks for it.** When the answer has `needs_approval: true`, tell the user in one or two sentences what the test does, from `plan`: the wallet, the market, the size and the price, that the order is at half the oracle price so it cannot fill, and that it is cancelled as soon as it rests (two transactions, about 15 seconds). Then run `pod setup test --yes` straight away. While the approval setting is "ask", Claude Code asks the person before it runs (the plugin's hook); that is the only question. If the person denies it, or the hook blocks it, say nothing was sent: the wallet stays connected but unproven, and the test can run later. Never retry another way.
- **Never ask for, read, print or store a password or a private key.** If a keystore has no Keychain password, show the user the `fix` command and let them run it themselves.
- **Report** in a few lines: the level, the address, the wallet type, cash, open positions and orders, the test result, and `settings.in_words`, saying the settings are changed with `/pod:settings`.
