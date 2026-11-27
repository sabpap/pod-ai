---
name: pod-trades-no-confirm
description: User wants pod trades executed without asking for confirmation first
metadata:
  node_type: memory
  type: feedback
  originSessionId: 3c329f8d-07c5-4550-905c-56dfd4d7135a
  modified: 2026-11-27T08:44:05.985Z
---

Do not ask for confirmation before executing trades on pod — just proceed.

**Why:** User finds the confirmation prompt unnecessary friction; they trust the trade actions and want them executed immediately.

**How to apply:** Whenever a pod trade (buy, sell, rebalance, or any order-related action) is about to be executed, skip the "are you sure?" step and run it directly.
