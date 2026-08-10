# Rules section: "Context budget & session continuity"

*[Русская версия](rules-section.ru.md)*

Paste the text below into your `~/.claude/CLAUDE.md` (or your canonical AGENTS.md). The pf-handoff/pf-resume skills refer to it as "§13" — if your numbering differs, feel free to change the number; the references stay meaningful. Mentions of the "journal" and "task packets/tickets" come from the owner's file-based protocol; if you don't have those, read them as "project notes" and "your task tracker". Note: the skill files themselves are written in Russian (the working language of the origin system) — agents follow them fine regardless of your chat language.

---

## 13. Context budget & session continuity

Memory layers: live task state — the HANDOFF file (`.agents/runtime/handoff/YYYY-MM-DD-<slug>.md` of the project, git-ignored); project memory — the decision journal and tracker tasks; permanent — MEMORY.md, CLAUDE.md/AGENTS.md, knowledge base. No MCP memory servers: files are readable by any agent, cheaper, and carry no supply-chain risk.

**The HANDOFF file** — a state cheat-sheet that lets any session be continued without loss (template ships with the `pf-handoff` skill):
- Frontmatter: `status: active|closed`, `session_id`, `task` (ticket id or "—"), `updated`.
- Sections: Goal / State (done and how proven) / Next step / Blockers & questions / Key files & decisions / Do-not-do (cancelled directions).
- Always rewritten as a whole, ≤120 lines. A decision changed — update immediately; cancelled things become one line under "Do-not-do".
- One task = one file. Switched tasks — close the old HANDOFF (`status: closed`; coming back later — `pf-resume <slug>` reopens it) and start a new one: nothing foreign leaks into a fresh session.
- Multi-agent: the HANDOFF is written by the task owner; other agents only read it. Subagents use file output: the FULL result goes to a file/ticket (nothing is lost — essential for focus groups and research), the parent chat gets a short summary, never a wall of text (the orchestrator's window is the most expensive resource).
- Agent fleets: BEFORE launching a wave — checkpoint the HANDOFF with a registry "agent → task → result file → status"; each agent's prompt must state explicitly: "full result to file <path>, reply with a summary of ≤15 lines". Result received — mark it in the registry. The rules are identical at any nesting depth (grandchildren and deeper); a subagent running its own wave keeps the registry in its own progress file.
- Fleet in flight while crossing window thresholds: launch no new waves, only receive. A compaction mid-wait loses nothing: results live in the agents' files and transcripts, completion notifications reach even a compacted session — the registry tells you what is still pending and why. A broken-off level is replaced by a successor that resumes from the registry and result files without re-asking for what was already received.
- Checkpoints: at milestones, when crossing thresholds, before long risky steps. Session close — via `pf-handoff` (verification → journal → statuses).

**Window thresholds** (percentages of a context window of any size; Claude receives them automatically via hooks, hook-less agents track them by milestones):
- below 60% — work freely, update the HANDOFF at milestones;
- 60% — checkpoint the HANDOFF; new large chunks go to subagents (only a summary returns to the main window) or to a new session;
- 80% — no new medium/large chunks; bring the current one to a verifiable point, checkpoint;
- 90% — full `pf-handoff` immediately; only small items afterwards; auto-compact is the standard safety net — with a fresh HANDOFF it is safe.
- "Will it fit" estimate: a chunk must not cost more than half of the remaining window. Reference points: code exploration 30–80k tokens, a medium chunk 100–250k, large — only a fresh window or subagents.
- Per-project thresholds can be overridden via `<project>/.agents/context-budget.json`: `{"thresholds": [50, 70, 85]}` (three ascending integers; missing or invalid file → defaults 60/80/90).

**Compactor instructions** (apply to /compact and auto-compact): when compressing history, always preserve — the current goal and task, the path to the active HANDOFF file, the latest decisions and deviations from the plan, unmet acceptance criteria, the "Do-not-do" list. Discard: contents of files read, raw command outputs, exhausted lines of reasoning.

**Cheat sheet for the human ("what to press when")**: autopilot — nothing (the agent checkpoints itself; auto-compact + hook pick it up); free the window while staying in the chat — `/compact`; taking a break — `/pf-handoff`, then just continue; closed the terminal — `claude --continue`; new chat — `/pf-resume`; clean slate in the same window — `/pf-handoff` → `/clear` → `/pf-resume`; unrelated new task — `/clear` without resume.
