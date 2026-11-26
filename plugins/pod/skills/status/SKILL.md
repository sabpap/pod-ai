---
name: status
description: Check whether pod can act on pod network right now, and what the agent can and cannot do there. Use when the user asks if pod is connected, working or ready, which wallet is in use, whether the agent can trade, or why something on pod failed.
argument-hint: "[--quick]"
---

# Status: can pod act right now?

1. Run `command -v pod && pod --version`. It must print `pod 1.1.0` or later. If pod is missing or older, tell the user to install it themselves from a copy of the pod-ai repository with `cli/install.sh`, and stop.
2. Run `pod status` (the full check, about 2 seconds) when the user asks; `pod status --quick` when you only need the facts. `pod status --help` says what every level and field means.
3. Tell the user, in a few lines: the `summary` line as given; each problem's `error` and `fix`; each warning; `settings.in_words`; and the capabilities only when asked what pod can do or when trading is not possible. Never paste the JSON.

"not set up" means: offer `/pod:setup`. Settings are changed with `/pod:settings`.
