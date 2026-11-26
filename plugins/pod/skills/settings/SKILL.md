---
name: settings
description: Show or change pod's trading settings - whether trades need the user's yes (approval ask or auto), the market-order band, and how long limit orders rest. Started only by the user.
argument-hint: "[approval ask|auto] [market_band_pct N] [default_ttl 1h]"
disable-model-invocation: true
---

# Settings: how trades are made

The user started this on purpose. Only they can, so switching approval off cannot start from the agent.

1. Run `command -v pod && pod --version`. It must print `pod 1.0.0` or later. If pod is missing or older, tell the user to install it themselves from a copy of the pod-ai repository with `cli/install.sh`, and stop.
2. Read `pod settings --help` for the settings, their values and what each does.
3. With no arguments, run `pod settings` and give the user the `in_words` line; offer to change any setting.
4. To change one, run `pod settings set KEY VALUE`, then report the new `in_words` line. Change only what the user asked for.
   - **approval auto** means the agent sends trades without asking. Before running it, ask with the AskUserQuestion tool: one question, two options: "Trade without asking" (description "From now on the agent sends trades with no Approve / Deny question") and "Keep asking". Run it only on "Trade without asking". Claude Code then also shows its own permission prompt (the plugin's hook), always, for this one change.
   - Switching back to **approval ask** needs no question.
