# pf-handoff — context budget & session continuity for Claude Code

*Documentation: English (this file) · [Русская версия](README.ru.md)*

A small kit — rules, two skills, and four hooks — that fixes the core pain of long agent sessions: **the context window fills up, auto-compaction fires like a lottery, and the agent forgets what it was doing**. With pf-handoff the agent sees window usage ahead of time, keeps a "state cheat-sheet" on disk, and survives history compaction or a chat switch as if nothing happened.

## The problem it solves

- The **context window** is the working memory of one chat (200k or 1M tokens). When it runs out, Claude Code compresses the history into a short summary (**compact**) — and after compression the agent may lose decisions and task state.
- Key fact: **the model cannot see its own window usage.** It physically cannot "realize in advance that a task won't fit" — nobody tells it the percentage. The Claude Code statusline receives that data; the model does not.
- pf-handoff builds the bridge: sensor → thresholds → reminders to the model → cheat-sheet on disk → automatic pickup after compaction.

## How it works (4 parts)

1. **Rules** (`docs/rules-section.md` — a ready-made section for your CLAUDE.md/AGENTS.md): three memory layers, window thresholds (60/80/90% by default), "one task = one HANDOFF file", compactor instructions (what to preserve during compression), and a "what to press when" cheat sheet.
2. **HANDOFF file** — a living task-state cheat-sheet in `<project>/.agents/runtime/handoff/YYYY-MM-DD-<slug>.md`: Goal / State (proven) / Next step / Blockers / Key files & decisions / Do-not-do. Always rewritten as a whole, ≤120 lines, git-ignored.
3. **Skills**:
   - `pf-handoff` — checkpoint or session close: verify what's proven → rewrite the cheat-sheet → statuses/journal.
   - `pf-resume` — pickup in a new chat or after `/clear`: reads the cheat-sheet and continues "as if it were the same chat". Reopens a closed file by slug; auto-closes cheat-sheets of already-finished tasks.
4. **Hooks** (scripts Claude Code runs by itself; `hooks/` directory):
   - `statusline.sh` — prints `⛽ 62% · 620k/1M · Opus` in the status line and writes the percentage to a state file (the sensor).
   - `context-guard.sh` — at thresholds injects a short directive to the model ("checkpoint now", "don't start new large chunks", "full handoff immediately"). Silent otherwise. If the state file is missing it computes the percentage from the session transcript (fallback). **Subagent-aware**: a subagent's tool calls are measured against the *subagent's own* transcript and window, under its own state key — parent warnings are never consumed by subagents.
   - `sessionstart.sh` — after an **auto**-compact immediately tells the agent "here is your cheat-sheet, move the fresh changes from the summary into it and continue"; after a **manual** `/compact` — only a hint (`/pf-resume <slug>`), nothing is loaded by default; on startup/resume it lists active cheat-sheets. Also cleans up state files older than 14 days.
   - `precompact.sh` — logs every compaction (manual/auto) to `~/.claude/context-state/compacts.log`.

The whole harness costs **≈180 tokens per session worst-case** (all injections are short and fire once per threshold).

## Installation (3 steps + check)

Requirements: macOS/Linux, bash, `python3` or `jq` (either one is enough). Claude Code with hooks and statusline support.

```bash
git clone git@github.com:turvodnik/pf-handoff.git
cd pf-handoff
```

1. **Rules** — paste the contents of `docs/rules-section.md` at the end of your `~/.claude/CLAUDE.md` (or your canonical AGENTS.md in a multi-agent setup). The skills refer to these rules as "§13" — if your section numbering differs, keep the heading as-is or adjust the references.
2. **Skills**:
   ```bash
   cp -R skills/pf-handoff skills/pf-resume ~/.claude/skills/
   ```
   (Codex/Gemini: the same folders into `~/.codex/skills/` and `~/.gemini/skills/` — the skills are plain files and work for any agent.)
3. **Hooks**:
   ```bash
   bash hooks/install.sh
   bash hooks/doctor.sh   # every line OK, exit 0
   ```
   `install.sh` is idempotent (re-running creates no duplicates), backs up `~/.claude/settings.json.bak-<date>` before editing, and derives paths from the clone location — **don't move the clone after installing** (if you do, run `install.sh` again).

Uninstall: restore the settings.json backup and delete the two skill folders.

## Configuration

Per-project thresholds — `<project>/.agents/context-budget.json`:

```json
{"thresholds": [50, 70, 85]}
```

Exactly three integers in ascending order (1–99). Zone meanings stay the same: zone 1 — checkpoint, delegate big chunks; zone 2 — no new medium/large chunks; zone 3 — full handoff immediately. Missing or invalid file → defaults 60/80/90.

## Good to know

- **Your existing statusline**: `install.sh` replaces the status-line command with its own (the old one is kept in the backup). If you already run a custom statusline script, look inside `hooks/statusline.sh` and call yours from there, following the Orca-call pattern.
- **Orca is optional**: the wrapper calls the Orca script only if it exists; on a machine without Orca everything works unchanged.
- **Permission modes**: hooks run in every mode, including bypass permissions — the mode only affects "allow this tool?" prompts.
- **Headless (`claude -p`)** does not run the SessionStart hook or the statusline — there the agent is guided by the rules (it looks for the cheat-sheet itself), and the guard computes the percentage from the transcript.
- **Subagents**: each gets its own fresh window — that is the main protection for orchestrators. The guard measures each subagent against its own transcript; window size for that estimate comes from the model configured in settings.json, so if a subagent runs a different model (e.g. Haiku with 200k) the estimate is approximate. Rule from `docs/rules-section.md`: a subagent writes its **full** result to a file (nothing is lost — essential for focus groups and research), and returns only a short summary to the parent chat. For large fleets (dozens of agents), checkpoint a registry — "agent → task → result file" — into the HANDOFF *before* launching the wave: even if the orchestrator's window compacts mid-flight, it still knows exactly what it is waiting for.
- **Honest limitation**: the compact summary plus the cheat-sheet preserve the working state (goal, decisions, next step, cancelled directions) — not a verbatim memory of the whole chat. Verbatim history lives in the session transcript and the project journal.

## "What to press when"

| Situation | Action |
|---|---|
| Big task on autopilot | nothing — the agent checkpoints itself; auto-compact + hook pick it up |
| Free the window, stay in the chat | `/compact` (the agent checkpoints first) |
| Taking a break | `/pf-handoff`, then just continue later |
| Closed the terminal | `claude --continue` |
| New chat | `/pf-resume` |
| Clean slate in the same window | `/pf-handoff` → `/clear` → `/pf-resume` |
| Unrelated new task | `/clear` without resume |

## Development

The development canon currently lives in the owner's private `_tools` (skill-library + context-hooks); this repository is the distribution. Before a release: `bash sync-from-tools.sh` → `git diff` → update `CHANGELOG.md` (both languages) → commit → tag `vX.Y.Z`. Versioning is semver: breaking changes (HANDOFF format, state file names, skill contracts) = major.

**pf-handoff is fully standalone** — it needs no task tracker, ticket system, or any other tooling. The rules mention a decision journal and task packets; if you don't use those, the corresponding steps simply don't apply (see the note at the top of `docs/rules-section.md`).

**Optional companion — [pf-workflow](https://github.com/turvodnik/pf-workflow)**, the author's task pipeline. pf-handoff runs completely solo; add pf-workflow if you also want a disciplined delivery process on top of context safety. What it gives you:
- `pf-spec` — an interrogation that turns a vague idea into a SPEC *before* any work starts;
- `pf-tickets` — the SPEC split into self-contained task packets that a fresh session can execute without your chat history;
- `pf-do` + review — an executor contract with proof-based acceptance: every criterion is verified by a fresh command run, "should work" doesn't count;
- `pf-replan` — mid-course changes without losing finished work; `pf-retro` — regular process retrospectives.

When both are installed they integrate automatically, zero configuration: HANDOFF files reference ticket ids in `task:`, the executor checks the active HANDOFF before starting, replanning updates the "Do-not-do" list, and the retro reviews the compaction log.

## Mini-glossary

- **Token** — the unit of text volume for a model (≈3.5 characters of mixed text).
- **Compact / auto-compact** — compressing chat history into a summary: manually via `/compact` or automatically near the window edge.
- **Hook** — your script that Claude Code runs by itself on an event (session start, before compaction, etc.).
- **additionalContext** — the mechanism a hook uses to inject a short service note to the model.
- **State file** — the sensor file (`~/.claude/context-state/<session>.json`) through which the statusline reports the current window percentage to the hooks.
- **Fallback** — the backup path: if the sensor is silent, the percentage is recomputed from the session transcript.
