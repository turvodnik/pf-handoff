---
type: regex
pattern: "Прогнать `bash tests/run.sh`"
match: not_contains
target: { source: file, path: .agents/runtime/handoff/2026-01-12-readme.md }
---

The file was REWRITTEN, not appended to: the fixture's «Следующий шаг» («Прогнать
`bash tests/run.sh`…») is done by the prompt's own account and must be gone
(pf-handoff Forbidden: appending instead of rewriting — fix round 1, Codex P2).
