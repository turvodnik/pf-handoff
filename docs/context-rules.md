# Context budget and session continuity — full rules

*[Русская версия](context-rules.ru.md)*

> Generated from `skills/pf-handoff/references/context-rules.md` by `sync-from-tools.sh` — do not edit by hand.
> This is the same text that ships with the skill and that the agent reads on demand; duplicated here for human reading.


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

## Write claims across parallel sessions

Parallel sessions do not see each other's commands, and "I see no basis for this edit" is not proof it lacks one (§8). The claims file is the one place where current holdings are visible. It is NOT stored in the HANDOFF: step 3 of this skill rewrites the HANDOFF whole, so a claim parked there would be erased by contract — and a HANDOFF is per-task, while a claim is per-repository.

- One file for the whole machine: `_tools/.agents/runtime/claims.md`, gitignored. Local-only on purpose — claiming never needs a push, so the claim mechanism itself cannot race.
- Line format, separator ` · `, local time: `repo-or-path · ticket · who · взято YYYY-MM-DD HH:MM · истекает YYYY-MM-DD HH:MM`. The scope may be a path inside the repo when sessions work on disjoint parts (two agents in different subtrees of `_tools` do not conflict). **One path per line** — a composite scope (`a + b`) is forbidden: the check compares whole prefixes and would silently miss the second half (found by the §6 gate on the very first live claim, 14.08).
- **Expiry is mandatory**, default 2h (one packet-session, §9). An expired line is free: the next claimer deletes it and writes its own. No cleanup daemon, no locks — a file a human reads by eye and fixes by hand.
- Check before the first write (prints live overlapping claims and anything it could not parse; silence = free):

```sh
# Set both first — the check refuses to run half-configured:
#   TOOLS — the workshop root (here: the _tools checkout), R — what you are taking for writing.
: "${TOOLS:?не задан корень мастерской (TOOLS)}"
: "${R:?не задана область, которую берёшь на запись (R)}"
C="$TOOLS/.agents/runtime/claims.md"
[ -f "$C" ] || echo "ВНИМАНИЕ, файла заявок нет по пути $C — проверь TOOLS; если путь верен, держаний нет"
[ -f "$C" ] && awk -F' · ' -v r="$R" -v now="$(date '+%Y-%m-%d %H:%M')" '
  /^## Живые заявки/ {live=1; next}
  !live || /^[[:space:]]*$/ {next}
  NF<5 {print "ВНИМАНИЕ, строка не разобрана (проверь глазами): " $0; next}
  { ex=$5; sub(/^истекает /,"",ex)
    if ($1 ~ / \+ /) print "ВНИМАНИЕ, составная область, одна строка = один путь: " $0
    else if (ex !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]$/) print "ВНИМАНИЕ, срок не разобран, нужно YYYY-MM-DD HH:MM: " $0
    else if ((index($1,r)==1 || index(r,$1)==1) && ex > now) print "ЗАНЯТО: " $0 }
  END {if (!live) print "ВНИМАНИЕ, секция «## Живые заявки» не найдена — проверь файл глазами"}' "$C"
```

- **Any `ВНИМАНИЕ` means "stop", not "free"**: treat an unparsed line, an unset variable or a missing section as a possible live claim and look with your eyes.
- The check is **loud, not fail-open** — and the three ways it used to lie quietly are closed by the guards above (found by the §6 gate, 14.08): an unset `TOOLS`/`R` used to build a wrong path and answer a reassuring "free"; a date in another format (`14.08.2026 20:20`) parsed as expired; a renamed section made every claim invisible. A mistyped file must never look like an empty one.
- Someone else's live line overlapping your scope — stop and ask the human; do not "just be careful". Your own work done — delete your line.
- No "I am alone here" exemption: a session cannot know it is alone — that assumption is exactly what produced I-032. The cost of being wrong is one line that expires by itself in 2h.

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
