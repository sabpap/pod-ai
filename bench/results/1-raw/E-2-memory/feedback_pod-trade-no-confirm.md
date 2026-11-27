---
name: pod-trade-no-confirm
description: Execute pod trades immediately without asking for user confirmation first
metadata:
  node_type: memory
  type: feedback
  originSessionId: d513e69a-c8b8-4454-ab1e-23af6080ec6f
  modified: 2026-11-27T09:00:12.800Z
---

Execute pod trades directly — do not ask for confirmation before submitting trade transactions.

**Why:** User wants a faster trading workflow and trusts the inputs they provide.

**How to apply:** When the user asks to buy, sell, or cancel on pod, execute the trade immediately without a "are you sure?" or "shall I proceed?" prompt. Still report the result after execution.
