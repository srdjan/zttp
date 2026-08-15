---
name: fix-violations
description: Fix all compiler violations in the current file by iterating until clean.
---
Work through every compiler violation in the current handler file systematically:
1. Read the target file before editing.
2. Run `zts_expert_verify_paths` to capture the pre-existing baseline.
3. For verifier/property failures, call `pi_repair_plan`.
4. For semantic proof repairs, use `pi_goal_candidate` to get verified `proposed_content` before drafting the edit.
5. For canonical ZTS6xx slips, obtain exact bound candidates from `zts_expert_canonicalize`, pass the selected candidates unchanged to `pi_apply_repair_plan`, and apply only its verified `proposed_content`.
6. After the edit lands, rely on the loop's post-apply `verify_paths` and `review_patch --diff-only` checks.

Do not introduce new violations while fixing existing ones. If a repair intent is unsupported, make the smallest manual edit that closes the reported diagnostic or witness.
