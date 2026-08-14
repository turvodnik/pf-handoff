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
- Line format, separator ` · `, local time: `scope · ticket · who · взято YYYY-MM-DD HH:MM · истекает YYYY-MM-DD HH:MM`. The scope may be a path inside the repo when sessions work on disjoint parts (two agents in different subtrees of `_tools` do not conflict). **One path per line** — a composite scope (`a + b`) is forbidden: the check compares whole prefixes and would silently miss the second half (found by the §6 gate on the very first live claim, 14.08).
- **Scope form: write `<repo>/<path>`** relative to the projects folder (`_tools/AGENTS.md`, `optimize/.agents/journal`) — that is the readable form for the human. Matching no longer depends on how the same path is *spelled*: the check canonicalizes **both sides** for real (`expanduser` → absolutize against the projects folder → `realpath` → NFC → case), so an absolute path, `~/…`, `..`, `./`, doubled or trailing slashes, a symlink on the way and a different Unicode form all resolve to the same claim. String comparison could not do this: four gate rounds produced four different aliases of one path, each one silence over a live claim (§6 gate, rounds 1–4, 13–14.08).
- **Expiry is mandatory**, default 2h (one packet-session, §9). An expired line is free: the next claimer deletes it and writes its own. No cleanup daemon, no locks — a file a human reads by eye and fixes by hand.
- **What is canonicalized is the *spelling*, not the meaning.** A relative path is read from the projects folder — the form the claims file uses. Your shell reads the same string from the current directory, so `cd <project>; claims-check.sh seo` has two legitimate readings; the script checks **both** and says `ВНИМАНИЕ, относительный путь неоднозначен` instead of silently picking one (§6 gate, closing round: that silent pick printed «свободно» over a live claim on the real file). One unambiguous answer costs one absolute path.
- Check before the first write — **one command**, any *spelling* of the path:

```sh
~/.claude/skills/pf-handoff/scripts/claims-check.sh "<what you are taking for writing>"
# ~/.codex/… and ~/.gemini/… are the same file; in a project without the global
# skill: bash <workshop>/skill-library/skills/pf-handoff/scripts/claims-check.sh
```

- **Three answers, and never silence** — an empty output can no longer pass for "free":
  - `ЗАНЯТО` (exit **1**) — a live claim overlaps yours, with who holds it and until when. Stop and ask the human.
  - `СВОБОДНО` (exit **0**) — the check ran and nothing overlaps. The other calm answer is `держаний нет` (the claims file was never created, while its directory is there).
  - `ВНИМАНИЕ` (exit **2**) — it could **not** check (an unparsed line, a date in another format, a renamed or missing section, an unreadable file, a claims path that is a broken symlink, an empty scope argument). Treat it exactly like `ЗАНЯТО` and look with your eyes. "I could not check" must never look like "I checked, it is clean" — that one confusion is what the §6 gate returned this packet for in rounds 1–4. Both states print together when both occur; the exit code is `ЗАНЯТО`'s, because both mean "do not write".
- The claims file is found **without configuration**: the script derives the workshop root from its own location (resolving the symlink chain of the surface it was called through), so a forgotten variable cannot build a wrong path and answer a reassuring "free". `TOOLS` and `CLAIMS_FILE` override it; a derived root with no `.agents/runtime` is `ВНИМАНИЕ`, not "free" — which is what a fresh clone of the public distribution gets until it points `TOOLS` at its own workshop. The calm "держаний нет" is reserved for a **derived** root: `.agents/runtime` exists in every project (§9), so an override like `TOOLS=$(pwd)` would otherwise answer calmly over a real file full of live claims. With an override in play, a missing claims file is `ВНИМАНИЕ` — on a genuinely fresh workshop, `touch` the file once and it goes quiet.
- Prefixes are compared **at path boundaries** (`_tools/security` does not claim `_tools/security-notes.md`, but does claim everything inside it), and the live section ends at the next `## ` heading — lines under an `## Архив` heading are history, not holdings.
- **Borders, named out loud** (a check that hides its limits is the thing being fixed here):
  - *Case* is folded only when the volume actually is case-insensitive — probed on this machine, not assumed from the OS name. On macOS `_Tools/x` and `_tools/x` are one file and must fold; on Linux/CI `Data/` and `data/` are two directories and folding would produce a false `ЗАНЯТО`. Cyrillic folds too on every platform (Python `str.lower()`), unlike `tolower` in `mawk`.
  - *Unicode form*: macOS hands out Cyrillic paths as NFC or NFD depending on how the string was produced; both sides are normalized to NFC, otherwise the same file compares unequal to itself.
  - *A claim is checked against paths, not against intent*: two sessions writing different lines of one file still collide, and the file is the unit.
  - The check is a **read-only helper, not a lock**: nothing enforces claiming, and a session that never runs it is invisible to the protocol.
- The old copy-paste `awk` snippet is **deleted, not kept as a fallback**: it under-promised in four consecutive rounds, and a second implementation of the matching rule is exactly the drift this protocol exists to prevent. The honest fallback is the one the warnings already name — read `claims.md` with your eyes.
- The script is canon; `doctor-agents.sh` goes red if it is missing from the surfaces or a surface copy has fallen behind canon — that is the price of a file over a snippet, and it is paid by the doctor, not by memory.
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
