---
type: regex
pattern: "- push pf-handoff наружу — владелец запретил до независимого QA"
target: { source: file, path: .agents/runtime/handoff/2026-01-12-readme.md }
---

First cancelled direction survives verbatim — the whole line, reason included
(fix round 1, Codex P2: a fragment would let the reason be dropped).
