---
name: fill-hole
description: "Fill one typed hole with one expression. Usage: /template:fill-hole <file>"
---
Fill the remaining hole in {{args}}. Read the frame with `zts_expert_holes`, then spend this turn on exactly one hole: call `zts_expert_fill_hole` with that hole's line and column and a single expression of the type the frame names. The frame is the whole specification of the expression, so do not rewrite the file. Commit the returned `proposed_content` only when the tool reports `ok`; when it does not, the expression was wrong rather than the file, so re-read the frame and write a different one at the same site.
