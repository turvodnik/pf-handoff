# Context budget and session continuity — full rules

Agent reference. Short pointers live in the global rules (§13); the details are here. Read when dealing with window thresholds, subagent swarms, or planning large chunks of work.

## Memory layers

- Live task state — the project's HANDOFF file `.agents/runtime/handoff/YYYY-MM-DD-<slug>.md` (in .gitignore).
- Project memory — the decision journal and task packets.
- Permanent — MEMORY.md, CLAUDE.md/AGENTS.md, the knowledge base. No MCP memory servers: plain files are readable by any agent, cheaper, and carry no supply-chain risk.

## The HANDOFF file

A state cheat-sheet from which any session can be resumed without loss (template — `references/handoff-template.md` of this skill; the file itself is written in Russian for the human).

- Frontmatter: `status: active|closed`, `session_id`, `task` (ticket id, `T-###` for the owner, or «—»), `updated`.
- Sections: Цель / Состояние (сделано и чем доказано) / Следующий шаг / Блокеры и вопросы / Ключевые файлы и решения / Не делать (отменённые направления).
- Always rewritten whole, ≤120 lines. A decision changed — update immediately; a cancelled direction — one line in «Не делать».
- One task = one file. The task changed — close the old file (`status: closed`; `pf-resume <slug>` reopens it later) and start a new one: someone else's state is not dragged into a fresh session.

## Multi-agent work and subagent swarms

- The HANDOFF is written by the task owner (ticket owner); other agents only read.
- Subagents get file-based output: the FULL result goes to a file/ticket (nothing is lost — vital for focus groups and research), the parent chat gets a short summary, not a wall of text (the orchestrator's window is the most expensive resource).
- BEFORE launching a wave — a HANDOFF checkpoint with a registry «агент → задача → файл результата → статус»; each subagent prompt says explicitly: "full result to file <path>, reply with a summary ≤15 lines". Result accepted — mark it in the registry.
- The rules are identical at any depth (grandchildren and below); a subagent running its own wave keeps the registry in its own progress file (ticket/workspace).
- Swarm in flight while crossing window thresholds: launch no new waves, only accept results. A compaction mid-wait loses nothing: results live in files and agent transcripts, completion notifications reach the compacted session too — the registry says what is still pending and why. A broken-off level is replaced by a successor: it continues from the registry and the result files, without re-asking for what was already accepted.

## Window thresholds

Percentages of a context window of any size. Claude receives them automatically via hooks; agents without hooks track them by milestones.

- up to 60% — work freely, update the HANDOFF at milestones;
- 60% — HANDOFF checkpoint; new large chunks go to subagents (only the summary returns to the main window) or to a new session;
- 80% — start no new medium/large (M/L) chunks; bring the current one to a verifiable point, checkpoint;
- 90% — full `pf-handoff` immediately; then only small items; auto-compaction is the normal safety net and is safe with a fresh HANDOFF.
- "Will it fit" estimate: a chunk must not cost more than half of the remaining window. Reference points: code recon 30–80k tokens, a medium (M) chunk 100–250k, a large (L) one — a fresh window or subagents only.
- Per-project thresholds are overridden by `<project>/.agents/context-budget.json`: `{"thresholds": [50, 70, 85]}` (three ascending integers; file missing or malformed — default 60/80/90).

## Checkpoints

At milestones, when crossing thresholds, before long risky steps. Session close — via `pf-handoff` (reconcile → journal → statuses).

## Human cheat-sheet ("when to press what")

Default — nothing (the agent checkpoints on its own; auto-compaction + the hook pick it up); clean the window while staying in the chat — `/compact`; pause — `/pf-handoff`, then just continue; closed the terminal — `claude --continue`; new chat — `/pf-resume`; fresh start in the same window — `/pf-handoff` → `/clear` → `/pf-resume`; an unrelated new task — `/clear` without resume.
