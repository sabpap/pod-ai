---
name: pod-trades-no-confirm
description: User does not want confirmation prompts before executing pod trades — just execute them
metadata:
  node_type: memory
  type: feedback
  originSessionId: 73bdf915-e822-4aeb-85b7-d77d25177717
  modified: 2026-11-27T08:46:52.405Z
---

Do not ask for confirmation before executing trades on pod. Just proceed.

**Why:** The user finds the confirmation prompts disruptive to their workflow. They are comfortable with pod trade operations being executed directly.

**How to apply:** When a pod trade action is requested, execute it immediately without pausing to ask "are you sure?" or similar confirmation steps. This overrides the general caution around actions that affect shared state for pod trades specifically.
