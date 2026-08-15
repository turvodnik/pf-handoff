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
- **In the workshop the claims file is found with no configuration; outside it, set `TOOLS` once.** The script derives the workshop root from its own location (resolving the symlink chain of the surface it was called through), so a forgotten variable cannot build a wrong path and answer a reassuring "free". The derived root is then *checked*, not trusted: it must actually look like a workshop (a `skill-library/` directory sits at it). It does not when the skill was installed as a plain **copy** — which is exactly what the public installer does into `~/.claude/skills/pf-handoff/`: four levels up from `scripts/` lands on `$HOME`, and with a `~/.agents/runtime` present the old code answered a calm "держаний нет" over a root that was never right. Now that case says `ВНИМАНИЕ` and names the fix: `TOOLS=<your workshop>` (or `CLAIMS_FILE` straight at the file), once. A derived workshop root with no `.agents/runtime` is `ВНИМАНИЕ` too, never "free". The calm "держаний нет" is reserved for a **derived** root: `.agents/runtime` exists in every project (§9), so an override like `TOOLS=$(pwd)` would otherwise answer calmly over a real file full of live claims. With an override in play, a missing claims file is `ВНИМАНИЕ` — on a genuinely fresh workshop, `touch` the file once and it goes quiet.
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

### Event log (measuring §8 compliance)

`claims.md` itself proves nothing over time: it lives under `.gitignore`
(`.agents/runtime/`) so `git log` can never see a single line from it — a
compliance count read from its history would be a guaranteed zero regardless
of how many claims actually happened (T-038/T-040, "could not check" ≠
"checked, clean"). To make the §8 measurement possible at all, every
`claims-check.sh` run appends **one line per check** to a versioned event
log, independent of the claim file's own gitignored lifecycle.

- Path: `<workshop>/.agents/claims-events.log` — inside `.agents/` but
  **outside** `.agents/runtime/` (that subtree stays gitignored) and
  **outside** `skill-library/skills/pf-handoff/` (that whole directory is
  `rsync --delete`d into the public `turvodnik/pf-handoff` distribution by
  `sync-from-tools.sh`; a log placed inside it would leak private events on
  every release, or force the log itself out of version control). `.agents/`
  is tracked by git (only its `runtime/` child is ignored) and is never
  synced out — the one place satisfying both constraints.
- One line per event, format `YYYY-MM-DD HH:MM · <scope, canonicalized> · <ВЕРДИКТ> · <who>` —
  timestamp, the checked scope after canonicalization (all its resolved
  forms, joined with ` | ` when the scope was ambiguous, newlines/CR folded
  to spaces so one event can never become two lines), the verdict
  (`СВОБОДНО`/`ЗАНЯТО`/`ВНИМАНИЕ`, matching the check's own exit code), and
  who ran it (`$CLAIMS_ACTOR` env var if set, sanitized the same way; else
  `user@host:pid`). No secret values ever appear here — only a path and a
  verdict (§5). **Known limit, named out loud, not hidden**: without
  `CLAIMS_ACTOR` the fallback distinguishes concurrent *processes* (the PID)
  but not repeated calls from the *same* session over time — full
  session-level attribution needs an agent that sets `CLAIMS_ACTOR` itself
  (e.g. `claude:T-040`); the log does not claim more precision than that.
- The append happens on **every** exit path of `claims-check.sh`, including
  the calm "держаний нет" case, so the log's event count matches the number
  of times the protocol was actually consulted, not just the number of
  overlaps found.
- The append is best-effort and never allowed to change the check's own
  verdict or exit code: a missing/unwritable log directory prints a loud
  `ПРЕДУПРЕЖДЕНИЕ` to stderr and the claim check still returns its correct
  `ЗАНЯТО`/`СВОБОДНО`/`ВНИМАНИЕ` — the class of bug this whole protocol
  exists to prevent is a check that goes silent or crashes instead of
  saying "I could not do X" out loud, and logging must not become a new
  instance of it. The directory under the log is only ever *created* when
  the root already looks like a real workshop (or the directory exists
  already) — a wrong/overridden `TOOLS` never spawns a stray `.agents/`
  in an unrelated place; it just prints the same warning and skips.
- `optimize/scripts/hygiene-sweep.sh` check 6 reads this log (when present)
  to report a real count of claim-check events over the period; absent the
  log it still gives the same honest "cannot count" phrase as before.

**Does writing this log itself violate the write-claim protocol it measures?
(fix-round 1, Codex P1)** No — by a named exemption, not a workaround.
`claims.md` is never claimed before it is edited either: requiring a claim
on the claim file to write the claim file is the exact recursion this
question describes, and the protocol has never asked for it. The reason is
structural, not accidental: `claims.md` is *protocol infrastructure*, not
content a session can semantically collide with another session over — two
sessions touching the *same file* still touch *different, non-overlapping
lines*, so §8 has always carved this class out in practice (the decision
journal §10 works the same way: many sessions append to one day's journal
file without claiming it, because appends do not conflict in meaning).
`claims-events.log` is the same class of file as `claims.md` — its
companion, not a new kind of thing — and inherits the same exemption:
- Every write is one `open(path, "a")` + one `write()` call of a single
  short line; POSIX guarantees that write is atomic (below `PIPE_BUF`), so
  concurrent processes interleave whole *lines*, never bytes within a line
  — the append cannot corrupt another session's event, only reorder events
  relative to each other, which does not affect a count.
- A dirty working tree between commits is the **expected** state of this
  file, exactly as it already is for a journal file mid-session — not a
  sign that something broke. Whoever commits their own ticket's work
  commits the log lines that accumulated alongside it, the same way §10
  already expects the day's journal entry to ride along with a commit.
- What *is* a genuine bug class, and is closed here: a test/probe run
  polluting the **real** log with fixture noise. `claims-check-probes.sh`
  sets `CLAIMS_LOG` for its entire run (see below) so a test event can
  never physically land in the tracked file regardless of what `TOOLS` the
  probe under test is exercising — the isolation does not depend on every
  individual probe getting `TOOLS` "right".
- `CLAIMS_LOG` (env var, mirrors `CLAIMS_FILE`) overrides the log path
  unconditionally, for exactly this reason: sandboxed tests point it at a
  disposable file, so from the point this variable exists, every line that
  ever lands in the real `.agents/claims-events.log` is a real event by
  construction, not by convention someone has to remember.

## Session start/finish ritual, L-task execution, model by role, drift watchdog

- **Start.** Read the project's AGENTS.md → the decision journal `.agents/journal/` for the last 3 days → task packets with status ≠ done → the active HANDOFF (this file's rules), if any → check the list of available skills and use the fitting one (do not invent a process a skill already describes).
- **Finish** (or a significant milestone): a journal entry (decision journal rules) + refresh the status of your own task packets + a `pf-handoff` checkpoint/close.
- **Executing part of an L-task** — in a fresh session under `pf-do`: context is the packet + AGENTS.md only, not the tail of someone else's chat (cheaper on limits and more accurate).
- **Model by role.** Thinking/designing/reviewing — the senior model; executing a ready plan — Sonnet-class.
- **Drift watchdog runs BY ITSELF, no need to remember it** (T-028): at session start — cheap levels 2-3 (the `drift-guard.sh --mode session` hook, +0.3s), the expensive level 1 — a pre-push hook on the `_tools` canon. Silence = checked and clean; if it could not run, it says so loudly. That both routes are in place is checked by `doctor-agents.sh`.

## Command provenance and not rolling back others' work

- **Command provenance.** Acting on a command received outside the shared channel (another window, a direct message) — quote it VERBATIM in «Результат» and in the commit message. A paraphrase ("at Vladimir's request") does not count: another session must see the basis, not take it on faith.
- **Do not roll back someone else's work on suspicion.** "I see no basis for this in my own conversation" is not proof — parallel sessions do not see each other's commands. Ask the human; rolling back someone else's work is exactly as irreversible as making the edit was. Cost of getting this wrong — incident I-032 (2026-08-13): a rollback of an agreed-upon canon edit plus a false accusation, both written twice into the permanent journal.
- **Push race.** Push rejected because someone else's commit landed first — `git pull --rebase` and retry; this is a normal race, not an incident, and never a reason for `--no-verify`.

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

## Automatic snapshot and the gate before compaction

Compaction is the moment state is lost, so a mechanical snapshot is taken **before every compaction** — automatic and manual `/compact` alike — and compaction does not proceed without one. Two hooks do it: `autocheckpoint.sh` writes the snapshot, `precompact.sh` (event `PreCompact`) calls it and returns exit code 2 — documented as "blocks compaction" — when nothing could be written.

- **What the snapshot is.** A file `<project>/.agents/runtime/handoff/<date>-auto-<session>.md` assembled by a script from facts visible on disk: branch, uncommitted changes, last commits, open task packets, live HANDOFF files, the last human turns from the transcript, window fill. It is **not** `pf-handoff`: a script cannot tell what is proven from what is merely claimed. The meaningful checkpoint is still the agent's job — the snapshot only guarantees that compaction never happens over nothing.
- **Where it lands.** The project directory first; if that is not writable (or the working directory is unknown), the emergency directory `~/.claude/context-state/handoff`. Only failing **both** blocks compaction.
- **Subagents are skipped on purpose**: a session id starting with `agent-` writes no snapshot (a subagent has its own short window and its own task; its file would be noise in the project). That is a deliberate skip, not a failure — the gate stays open.
- **Compaction at the same level.** The hooks do not compact anything; only the harness can. Set `autoCompactWindow` in `~/.claude/settings.json` to fire auto-compaction near the same 80% level — the field counts **tokens, not percent** (e.g. 160000 for a 200k window). Unset, compaction happens at the model's limit; `doctor.sh` reports which of the two you are on.
- **The price, said out loud.** The gate can block compaction: a hard stop, not a warning. It fires when the snapshot could not be written anywhere — an unwritable project and home directory, `autocheckpoint.sh` missing next to `precompact.sh`, or **neither `jq` nor `python3` on PATH** (with no JSON reader the payload cannot be parsed, no session can be named, and no snapshot can be written — so one of the two is effectively a requirement of the gate). A payload the hook cannot parse at all lands in the same place, and there is a reason to prefer it that way: silently compacting while preserving nothing is the failure this whole mechanism exists to prevent ("could not check" must never look like "checked, clean").
- **Ways out of a block**, in the order to try them: run `pf-handoff` by hand (a full checkpoint, after which nothing is lost by compacting); fix write permissions on `<project>/.agents/runtime/handoff` and `~/.claude/context-state/handoff`; install `jq` or `python3`; as a last resort remove the `PreCompact` entry from `~/.claude/settings.json` — compaction is unblocked immediately and the safety net is gone with it. The reason is never silent: the hook prints it to stderr (in English, with a one-line Russian summary), and every attempt is logged in `~/.claude/context-state/compacts.log` — `OK <file>`, `BLOCKED-no-checkpoint`, `SKIPPED-subagent` (a subagent session, no snapshot by design) or `SKIPPED-empty-stdin` (no payload arrived at all: compaction is allowed, because a stop there would wedge any environment that fails to deliver stdin, but the line makes it visible afterwards).
- **The gate needs `bash`.** The installer registers the hooks naming the interpreter explicitly (`bash '<hook>'`), because the harness runs the command through the system shell and on Debian/Ubuntu that is `dash`, which cannot read these scripts. If `bash` is not on `PATH` at all, the registration wrapper drains stdin and exits 0: the hooks self-disable rather than block anything. Updating from an older version, run `bash install.sh` once — it now rewrites its own stale entries instead of leaving them.

## Human cheat-sheet ("when to press what")

Default — nothing (the agent checkpoints on its own; auto-compaction + the hook pick it up); clean the window while staying in the chat — `/compact`; pause — `/pf-handoff`, then just continue; closed the terminal — `claude --continue`; new chat — `/pf-resume`; fresh start in the same window — `/pf-handoff` → `/clear` → `/pf-resume`; an unrelated new task — `/clear` without resume.
