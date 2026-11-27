---
name: pod-trades-no-confirm
description: Execute pod trades immediately without asking the user for confirmation first
metadata:
  node_type: memory
  type: feedback
  originSessionId: b468e057-6a3d-4e00-9ec6-e825c3200c1a
  modified: 2026-11-27T09:07:15.576Z
---

Execute pod trades directly — do not ask for confirmation before submitting buy, sell, or cancel orders.

**Why:** The user finds the confirmation prompt unnecessary friction; they trust their own trade instructions and want immediate execution.

**How to apply:** When the user asks to place a trade (buy/sell/cancel) on pod, execute it right away. Skip any "are you sure?" or "shall I proceed?" prompts.
