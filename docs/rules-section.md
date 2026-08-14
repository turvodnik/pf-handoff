# Rules section: "Context budget & session continuity"

*[Русская версия](rules-section.ru.md)*

Paste the text below into your `~/.claude/CLAUDE.md` (or your canonical AGENTS.md). It is deliberately short: everything here is loaded into **every** window at startup, so it carries only the invariants that must apply even when no skill is loaded. The full rules live in a file the agent reads on demand — `~/.claude/skills/pf-handoff/references/context-rules.md` (ships with the skill); the same text is mirrored in this repository as [`context-rules.md`](context-rules.md).

The pf-handoff/pf-resume skills refer to this section as "§13" — if your numbering differs, feel free to change the number; the references stay meaningful. Mentions of the "journal" and "task packets/tickets" come from the owner's file-based protocol; if you don't have those, read them as "project notes" and "your task tracker". The skill instructions are written in English; the origin system's working chat language is Russian, and the skills keep the artifact templates (HANDOFF sections) in that language — replace them with yours if needed. (Older versions of this doc showed the HANDOFF section names in English translation — «Goal / State / …»; nothing changed in behavior: the sections were always written per the shipped Russian template, the docs now simply show the literal names.)

---

## 13. Context budget & session continuity

Live task state — the HANDOFF file `.agents/runtime/handoff/YYYY-MM-DD-<slug>.md` of the project (git-ignored); project memory — the decision journal and tracker tasks; permanent — MEMORY.md, CLAUDE.md/AGENTS.md, knowledge base. Full rules (HANDOFF format, multi-agent fleets, checkpoints, human cheat sheet) — the `pf-handoff` skill, `references/context-rules.md`; agents without that skill read it directly at `~/.claude/skills/pf-handoff/references/context-rules.md` (or `~/.codex/skills/…`, `~/.gemini/skills/…`).

Always, even with no skill loaded:
- **Window thresholds** 60/80/90% (60 — checkpoint the HANDOFF, hand large chunks to subagents; 80 — start no new medium/large chunks; 90 — full `pf-handoff` immediately). Claude receives the thresholds via hooks; hook-less agents track them by milestones. Override per project: `<project>/.agents/context-budget.json`: `{"thresholds": [50, 70, 85]}`.
- **Agent fleets**: before a wave — checkpoint the HANDOFF with a registry "agent → task → result file → status"; each subagent writes its FULL result to a file and returns a summary of ≤15 lines to the parent chat.
- **Automatic snapshot and the gate before compaction**: before EVERY compaction — automatic and manual `/compact` alike — a hook writes a mechanical state snapshot by itself (`.agents/runtime/handoff/<date>-auto-<session>.md`); the snapshot is a safety net, not `pf-handoff` — the meaningful checkpoint is still the agent's job. If the snapshot could not be written, compaction is **blocked** (`PreCompact`, exit 2) and staying quiet about it is not allowed. Compaction at the same level is fired by the harness: `autoCompactWindow` in `~/.claude/settings.json` (the value is in tokens, not percent). The price of a block and the ways out — [`context-rules.md`](context-rules.md).

**Compactor instructions** (apply to /compact and auto-compact): when compressing history, always preserve — the current goal and task, the path to the active HANDOFF file, the latest decisions and deviations from the plan, unmet acceptance criteria, the "Do-not-do" list. Discard: contents of files read, raw command outputs, exhausted lines of reasoning.
