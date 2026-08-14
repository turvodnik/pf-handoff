# pf-handoff — context budget & session continuity for Claude Code

[![tests](https://github.com/turvodnik/pf-handoff/actions/workflows/tests.yml/badge.svg)](https://github.com/turvodnik/pf-handoff/actions/workflows/tests.yml)

*Documentation: English (this file) · [Русская версия](README.ru.md)*

A small kit — rules, two skills, and four hooks — that fixes the core pain of long agent sessions: **the context window fills up, auto-compaction fires like a lottery, and the agent forgets what it was doing**. With pf-handoff the agent sees window usage ahead of time, keeps a "state cheat-sheet" on disk, and survives history compaction or a chat switch as if nothing happened.

## The problem it solves

- The **context window** is the working memory of one chat (200k or 1M tokens). When it runs out, Claude Code compresses the history into a short summary (**compact**) — and after compression the agent may lose decisions and task state.
- Key fact: **the model cannot see its own window usage.** It physically cannot "realize in advance that a task won't fit" — nobody tells it the percentage. The Claude Code statusline receives that data; the model does not.
- pf-handoff builds the bridge: sensor → thresholds → reminders to the model → cheat-sheet on disk → automatic pickup after compaction.

## How it works (4 parts)

1. **Rules** — two files, split by cost. `docs/rules-section.md` is the short section you paste into your CLAUDE.md/AGENTS.md: it loads into *every* window, so it holds only the invariants (memory layers, window thresholds 60/80/90%, the fleet registry rule, compactor instructions). [`docs/context-rules.md`](docs/context-rules.md) holds the full rules (HANDOFF format, multi-agent fleets, checkpoints, the "what to press when" cheat sheet) — the agent reads them on demand from the copy that ships with the skill (`~/.claude/skills/pf-handoff/references/context-rules.md`). The split keeps roughly 600 tokens out of every session start (measured on the English section; the Russian one saves about twice that).
2. **HANDOFF file** — a living task-state cheat-sheet in `<project>/.agents/runtime/handoff/YYYY-MM-DD-<slug>.md`: Goal / State (proven) / Next step / Blockers / Key files & decisions / Do-not-do. Always rewritten as a whole, ≤120 lines, git-ignored.
3. **Skills**:
   - `pf-handoff` — checkpoint or session close: verify what's proven → rewrite the cheat-sheet → statuses/journal.
   - `pf-resume` — pickup in a new chat or after `/clear`: reads the cheat-sheet and continues "as if it were the same chat". Reopens a closed file by slug; auto-closes cheat-sheets of already-finished tasks.
4. **Hooks** (scripts Claude Code runs by itself; `hooks/` directory):
   - `statusline.sh` — a two-line rich status bar (ccstatusline-style, zero dependencies) and the sensor writing the window percentage to a state file:
     `Model: Fable 5 | Effort: medium | Context: [██░░░░░░░░░░░░░░░░░░] 110k/1.0M (11%) | ⎇ main(+0,-0)`
     `Session: 0.0% | Reset: 4hr 56m | Weekly: 18.0% | Weekly Reset: 4d 12hr 6m`
     The bar colour follows the zones (green < 60%, yellow 60–79%, red ≥ 80%); Session/Weekly show your subscription rate limits with time to reset; the branch segment shows lines added/removed this session. Segments degrade gracefully when data is absent. Renders in the Claude Code terminal (other CLIs have no custom-statusline hook; the desktop app doesn't render a status line — the sensor falls back to transcript parsing there).
   - `context-guard.sh` — at thresholds injects a short directive to the model ("checkpoint now", "don't start new large chunks", "full handoff immediately"). Silent otherwise. If the state file is missing it computes the percentage from the session transcript (fallback). **Subagent-aware**: a subagent's tool calls are measured against the *subagent's own* transcript and window, under its own state key — parent warnings are never consumed by subagents.
   - `sessionstart.sh` — after an **auto**-compact immediately tells the agent "here is your cheat-sheet, move the fresh changes from the summary into it and continue"; after a **manual** `/compact` — only a hint (`/pf-resume <slug>`), nothing is loaded by default; on startup/resume it lists active cheat-sheets. Also cleans up state files older than 14 days.
   - `precompact.sh` — **the gate before compaction**: on every compaction (manual `/compact` and automatic alike) it calls `autocheckpoint.sh` to write a state snapshot, logs the attempt to `~/.claude/context-state/compacts.log`, and **stops the compaction (exit 2) if no snapshot could be written anywhere**. See ["The gate before compaction"](#the-gate-before-compaction) below — it is the one part of this kit that can say "no".
   - `autocheckpoint.sh` — not registered in `settings.json`; the two hooks above call it directly. It assembles the snapshot `<project>/.agents/runtime/handoff/<date>-auto-<session>.md` from facts on disk (branch, uncommitted changes, last commits, open task packets, live cheat-sheets, the last human turns, window fill). It is *not* a `pf-handoff` checkpoint — a script cannot tell what is proven from what is merely claimed; it only guarantees that compaction never happens over nothing.

The whole harness costs **≈180 tokens per session worst-case** (all injections are short and fire once per threshold).

### The gate before compaction

Compaction is the moment state is lost, so since v1.10.0 it does not happen without a snapshot. Most of the time you never notice: the snapshot is written, the hook is silent, compaction proceeds.

- **When it blocks.** Only when the snapshot could not be written **anywhere**: the project directory is unwritable *and* so is the emergency directory `~/.claude/context-state/handoff`; or `autocheckpoint.sh` is missing next to `precompact.sh`; or neither `jq` nor `python3` is on `PATH` (with no JSON reader the session cannot be named, so no snapshot can be written); or the payload could not be parsed at all. A **subagent** session writes no snapshot by design and is never blocked.
- **What you see.** A `[COMPACTION STOPPED]` message on stderr naming the reason and the ways out, and a line in `~/.claude/context-state/compacts.log` (`OK <file>`, `BLOCKED-no-checkpoint`, `SKIPPED-subagent`, `SKIPPED-empty-stdin`).
- **Ways out**, in order: run the `pf-handoff` skill by hand (a full checkpoint — after it, compacting loses nothing); fix write permissions on `<project>/.agents/runtime/handoff` and `~/.claude/context-state/handoff`; install `jq` or `python3`; as a last resort delete the `PreCompact` entry from `~/.claude/settings.json` — compaction is unblocked immediately, and the safety net goes with it.
- **Why a hard stop rather than a warning**: compacting while nothing was preserved is exactly the loss this kit exists to prevent, and a warning nobody reads looks identical to success.

## Installation (3 steps + check)

Requirements: macOS/Linux, **bash** (the installer registers the hooks naming the interpreter explicitly, because on Debian/Ubuntu `/bin/sh` is dash and cannot read these scripts; with no bash on `PATH` the hooks self-disable instead of blocking anything), `python3` or `jq` (either one is enough — the gate above needs one of them). Claude Code with hooks and statusline support.

```bash
git clone https://github.com/turvodnik/pf-handoff.git
cd pf-handoff
bash install.sh
```

That's it for the automated part: the installer copies both skills (as plain copies — to `~/.claude/skills`, plus `~/.codex`/`~/.gemini` if those CLIs exist), registers the hooks in `~/.claude/settings.json` (backing it up first; a missing settings.json is created), and runs the health check — every line should say OK.

The one manual step: **paste the contents of `docs/rules-section.md`** at the end of your `~/.claude/CLAUDE.md` (or your canonical AGENTS.md in a multi-agent setup). The skills refer to these rules as "§13" — if your section numbering differs, keep the heading as-is or adjust the references.

Notes:
- The skills are installed as **copies**, so you may move or delete the clone afterwards; to update, `git pull && bash install.sh`. The hook entries in settings.json point at the clone's `hooks/` directory — if you move the clone, re-run `bash install.sh` from the new location.
- If a skill already exists as a **symlink** (you manage skills with your own tooling), the installer skips it and says so.
- Everything is idempotent: re-running creates no duplicates. Since v1.10.0 the installer also **rewrites its own outdated hook entries** instead of leaving them alone — updating from v1.9.0 or earlier, run `bash install.sh` once, otherwise the old registration (which broke every hook on Debian/Ubuntu) would stay in your `settings.json`.

Uninstall: restore the settings.json backup and delete the two skill folders.

## Configuration

Per-project thresholds — `<project>/.agents/context-budget.json`:

```json
{"thresholds": [50, 70, 85]}
```

Exactly three integers in ascending order (1–99). Zone meanings stay the same: zone 1 — checkpoint, delegate big chunks; zone 2 — no new medium/large chunks; zone 3 — full handoff immediately. Missing or invalid file → defaults 60/80/90. The status-bar colour follows the same project thresholds.

Status bar look & widgets — `~/.config/pf-handoff/statusline.json` (optional; without it the default look is used):

```json
{
  "line1": ["model", "effort", "context", "branch"],
  "line2": ["session", "weekly"],
  "bar_width": 20,
  "bar_filled": "█",
  "bar_empty": "░",
  "separator": " | ",
  "colors": true
}
```

- Widgets: `model`, `effort` (the model's reasoning-effort level, when the CLI reports one), `context` (bar + tokens/window + %), `branch` (git branch with session +/− line counts), `session` (5-hour limit % + Reset), `weekly` (weekly % + Weekly Reset), `cost` (session USD), `duration` (session time). Unknown names are silently skipped; a widget with no data disappears by itself.
- An **absent** `line1`/`line2` key keeps the default; an **explicitly empty** array (`"line2": []`) disables that line.
- `bar_width` accepts 5–60; `colors: false` renders plain text (no ANSI).

Quick start & feedback loop:

```bash
mkdir -p ~/.config/pf-handoff && cp examples/statusline.json ~/.config/pf-handoff/
bash hooks/statusline.sh --preview   # instant render with sample data — edit the config and re-run
bash hooks/doctor.sh                 # also validates the config and says WHY it would be ignored
```

## Good to know

- **Your existing statusline**: `install.sh` replaces the status-line command with its own (the old one is kept in the backup). If you already run a custom statusline script, look inside `hooks/statusline.sh` and call yours from there, following the Orca-call pattern.
- **Orca is optional**: the wrapper calls the Orca script only if it exists; on a machine without Orca everything works unchanged.
- **Permission modes**: hooks run in every mode, including bypass permissions — the mode only affects "allow this tool?" prompts.
- **Headless (`claude -p`)** does not run the SessionStart hook or the statusline — there the agent is guided by the rules (it looks for the cheat-sheet itself), and the guard computes the percentage from the transcript.
- **Subagents**: each gets its own fresh window — that is the main protection for orchestrators. The guard measures each subagent against its own transcript; window size for that estimate comes from the model configured in settings.json, so if a subagent runs a different model (e.g. Haiku with 200k) the estimate is approximate. Rule from `docs/context-rules.md`: a subagent writes its **full** result to a file (nothing is lost — essential for focus groups and research), and returns only a short summary to the parent chat. For large fleets (dozens of agents), checkpoint a registry — "agent → task → result file" — into the HANDOFF *before* launching the wave: even if the orchestrator's window compacts mid-flight, it still knows exactly what it is waiting for. Verified to work at **any nesting depth** (children, grandchildren, …): every level gets its own agent id and a flat transcript in the session's `subagents/` directory, so the guard measures each one individually — with a `find`-based fallback in case the directory layout ever changes.
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

Run the test suite locally with `bash tests/run.sh` (bash 3.2+, coreutils, `jq` and `python3` — the hooks-never-crash matrix builds curated jq-only/python3-only PATH sandboxes and aborts without either, not a graceful skip. ShellCheck and PyYAML are the only genuinely optional pieces, skipped with a reason when absent). The same command runs in CI on every push and pull request ([`.github/workflows/tests.yml`](.github/workflows/tests.yml)).

**pf-handoff is fully standalone** — it needs no task tracker, ticket system, or any other tooling. The rules mention a decision journal and task packets; if you don't use those, the corresponding steps simply don't apply (see the note at the top of `docs/rules-section.md`).

**Optional companion — [pf-workflow](https://github.com/turvodnik/pf-workflow)**, the author's task pipeline. pf-handoff runs completely solo; add pf-workflow if you also want a disciplined delivery process on top of context safety. What it gives you:
- `pf-spec` — an interrogation that turns a vague idea into a SPEC *before* any work starts;
- `pf-tickets` — the SPEC split into self-contained task packets that a fresh session can execute without your chat history;
- `pf-do` + review — an executor contract with proof-based acceptance: every criterion is verified by a fresh command run, "should work" doesn't count;
- `pf-replan` — mid-course changes without losing finished work; `pf-retro` — regular process retrospectives.

When both are installed they integrate automatically, zero configuration: HANDOFF files reference ticket ids in `task:`, the executor checks the active HANDOFF before starting, replanning updates the "Do-not-do" list, and the retro reviews the compaction log.

One integration reaches outside your machine's free tooling and is therefore strictly opt-in. Four conditions must all hold: pf-workflow is installed (it ships the review script), the OpenAI Codex CLI is present, the project's `.agents/codex-review.json` says `{"enabled": true}`, and the closing session still holds uncommitted code. Then closing runs a read-only Codex review of that code and puts the report path into the HANDOFF. Codex is a paid third-party CLI; miss any of the four conditions and the step is skipped silently, exactly as before.

## Mini-glossary

- **Token** — the unit of text volume for a model (≈3.5 characters of mixed text).
- **Compact / auto-compact** — compressing chat history into a summary: manually via `/compact` or automatically near the window edge.
- **Hook** — your script that Claude Code runs by itself on an event (session start, before compaction, etc.).
- **additionalContext** — the mechanism a hook uses to inject a short service note to the model.
- **State file** — the sensor file (`~/.claude/context-state/<session>.json`) through which the statusline reports the current window percentage to the hooks.
- **Fallback** — the backup path: if the sensor is silent, the percentage is recomputed from the session transcript.
