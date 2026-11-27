---
name: pod-trades-no-confirm
description: User does not want confirmation prompts before executing trades on pod — just send them
metadata:
  node_type: memory
  type: feedback
  originSessionId: 338cfefe-9db7-4728-849a-1008f13f6ec8
  modified: 2026-11-27T09:18:49.479Z
---

Execute pod trades immediately without asking for confirmation first.

**Why:** The user finds the extra confirmation step unnecessary friction — they know what they're asking for when they request a trade.

**How to apply:** When the user asks to buy, sell, short, close, set a stop-loss/take-profit, edit or cancel orders, or any other trading action on pod, execute it directly. Do not ask "Are you sure?" or present a summary for approval before sending.
