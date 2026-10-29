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
6. After the edit lands, rely on the loop's post-apply `verify_paths` check.

For ZTS303 (a Result use that the proof refuses), the `summary` of the plan names the shape. Repair each shape as follows:
- Unguarded `.value` read: add `if (!r.ok) return ...;` before the read.
- `.error` read: read it after `if (!r.ok)`, or write `r.error ?? fallback`. On the ok path, use `if (r.ok) return ...;` first.
- Alias, argument, return, object or array member, or spread: check `r.ok` in this function, then use `r.value`, not `r`. Pass `r` itself only to a `zttp:result` function that takes a Result.
- Method call, `=== true`, or `match`: replace it with `if (!r.ok) return ...;`.
- Unbound call such as `requestJson(req).value`: bind the call to a `const`, then check `.ok`.
- Closure read: check `.ok` inside the closure.
- Read inside `assert`, `switch`, or `try`: check `.ok` in an `if` before that statement.

For ZTS309 (a read on a value that may be undefined), repair each form as follows:
- Plain binding `p.age`: add `if (p === undefined) return ...;` before the read, or write `p?.age ?? fallback`.
- Index read `ps[0].age`: bind it with `const first = ps[0];`, then add `if (first === undefined) return ...;` before `first.age`.
- Call result `find(xs).age`: bind the call to a `const`, then check it for undefined.
- Do not delete the read to silence the diagnostic. Keep the response fields that the handler had.
- A check does not cover an `unknown` value, `req.headers`, `req.query`, `req.params`, or a `null` value. Those reads are unchecked, so keep them safe by hand.

For ZTS201 on a parsed JSON value or a Dict (a member or index read that yields undefined), repair each form as follows:
- A field read on the `.value` of `requestJson`, `parseJson`, or `parseJsonBytes`: decode with `decodeJson(schema, req.body ?? "")` and read the decoded value.
- Without a schema: check `isDict(v)`, then read with `dictGet(v, "name")` from `zttp:collections`. Never write `v.name`.
- A Dict member or index read `d.key` or `d["key"]`: write `dictGet(d, "key")`.

Do not introduce new violations while fixing existing ones. If a repair intent is unsupported, make the smallest manual edit that closes the reported diagnostic or witness.
