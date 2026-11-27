---
name: pod-trades-no-confirm
description: Do not ask for confirmation before executing pod trades — proceed directly
metadata:
  node_type: memory
  type: feedback
  originSessionId: 66a01919-8219-468f-b67b-0c5a97837f41
  modified: 2026-11-27T07:41:48.531Z
---

Do not ask for confirmation before executing trades on pod. Just proceed.

**Why:** User finds the confirmation prompts unnecessary friction — they trust the trade flow and want it executed without pausing.

**How to apply:** When a pod trade action is requested, execute it immediately without asking "are you sure?" or similar confirmations.
