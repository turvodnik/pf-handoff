---
type: regex
pattern: "\\nupdated: \\d{4}-\\d{2}-\\d{2} 09:00\\n"
match: not_contains
target: { source: file, path: .agents/runtime/handoff/2026-01-12-readme.md }
---

`updated:` no longer carries the fixture's 09:00 stamp — pf-handoff step 4
refreshes it on every rewrite (an append leaves it in place).
