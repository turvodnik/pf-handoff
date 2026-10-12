---
type: regex
pattern: "## Состояние[\\s\\S]*(3/3[\\s\\S]*abc1234|abc1234[\\s\\S]*3/3)"
target: { source: file, path: .agents/runtime/handoff/2026-01-12-readme.md }
---

Both new facts (tests 3/3 and commit abc1234) landed under «Состояние» — the
checkpoint recorded what was proven, not one of the two (fix round 1, Codex P3);
either order (fix round 2: «коммит abc1234 — тесты 3/3» is as valid).
