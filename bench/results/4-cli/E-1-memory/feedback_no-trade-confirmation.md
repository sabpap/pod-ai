---
name: no-trade-confirmation
description: Execute pod trades immediately without asking for user confirmation first
metadata:
  node_type: memory
  type: feedback
  originSessionId: 452bb3aa-434b-4b13-8cfc-aa6a96467a27
  modified: 2026-11-27T09:15:45.486Z
---

Do not ask for confirmation before executing trades on pod — just send them.

**Why:** The user finds the confirmation prompt unnecessary friction; they trust their own instructions and want trades executed directly.

**How to apply:** When the user asks to buy, sell, short, close, set a stop-loss, take-profit, or any other trade action on pod, execute it immediately without a "are you sure?" or "shall I proceed?" prompt.
