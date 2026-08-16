---
name: write-test
description: "Write a test case for a handler path. Usage: /template:write-test <description>"
---
Write a test case for: {{args}}. Read the handler and adjacent tests first, derive the JSONL from compiler-proven behavior, then submit the complete source change through one `propose_change_set` call.
