---
type: regex
pattern: "^-{3}\\nstatus: active\\nsession_id: 7e5f3a9b-demo\\ntask: T-001\\nupdated: \\d{4}-\\d{2}-\\d{2} 18:40\\n-{3}\\n"
target: { source: file, path: .agents/runtime/handoff/2026-01-02-parser.md }
---

The consumer check: the HANDOFF frontmatter is exactly the fixture's — still
`active`, original `updated:` — so nothing continued or «fixed» it by any tool.
(`-{3}` instead of a literal `---`: the CLI's frontmatter splitter stops at the first
`---` it sees inside a value — found live, fix round 1.)
