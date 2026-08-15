---
name: fix
description: "Fix a specific violation or error. Usage: /template:fix <error>"
---
Fix the following issue in the handler: {{args}}. Read the file and run `zts_expert_verify_paths`. For a semantic proof failure, use `pi_repair_plan` plus `pi_goal_candidate`. For a canonical violation, take exact bound candidates from `zts_expert_canonicalize` and preview them unchanged with `pi_apply_repair_plan`. Apply only the smallest verified result. Explain the root cause only after the compiler accepts the fix.
