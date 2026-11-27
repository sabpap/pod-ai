---
name: pod-trade-no-confirm
description: Execute pod trades immediately without asking for user confirmation first
metadata:
  node_type: memory
  type: feedback
  originSessionId: 4da53d68-519e-44f2-ba2b-4a01d1d5fc5d
  modified: 2026-11-27T09:17:46.483Z
---

Do not ask for confirmation before executing trades on pod — just send them.

**Why:** The user finds the confirmation prompt unnecessary friction; they trust their own instructions and want trades executed immediately.

**How to apply:** When the user asks to buy, sell, short, close, set a stop-loss, take-profit, or any other trade action on pod, execute it directly without a "are you sure?" or "shall I proceed?" step.
