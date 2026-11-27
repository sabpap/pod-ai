---
name: pod-trades-no-confirm
description: User does not want confirmation prompts before executing pod trades
metadata:
  node_type: memory
  type: feedback
  originSessionId: 01d18b66-f76d-4030-a420-577e4caacdd2
  modified: 2026-11-27T08:49:21.460Z
---

Do not ask for confirmation before executing trades on pod — just proceed.

**Why:** The user finds the confirmation step unnecessary friction; they trust the trade parameters they provide and want immediate execution.

**How to apply:** When the user requests a pod trade (buy, sell, rebalance, etc.), execute it directly without pausing to ask "are you sure?" or summarising the trade for approval first.
