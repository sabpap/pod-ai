---
name: pod-trade-no-confirm
description: Execute pod trades immediately without asking for user confirmation first
metadata:
  node_type: memory
  type: feedback
  originSessionId: b21ddf2f-b89e-4470-a90a-ac09fbbeccc1
  modified: 2026-11-27T08:51:55.112Z
---

Execute pod trades (buy, sell, cancel) directly without asking for confirmation.

**Why:** The user finds the confirmation prompt unnecessary friction — they already stated the intent by asking for the trade.

**How to apply:** When the user asks to place or cancel an order on pod, proceed immediately with signing and submitting the transaction. Do not pause to summarize the order and ask "shall I go ahead?"
