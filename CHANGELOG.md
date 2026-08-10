# Changelog

*[Русская версия](CHANGELOG.ru.md)*

Semver: breaking changes (HANDOFF file format, state file names, skill contracts, install scheme) = major; new features = minor; fixes = patch.

## v1.4.0 — 2026-08-10

Clean-machine install fixes — every issue below was reproduced in a sandbox (fresh $HOME, anonymous clone from GitHub) and re-tested green (21/21) after the fix:

- **New root `install.sh`** — one-command install: copies both skills (plain copies, the clone may be moved or deleted afterwards; `~/.codex`/`~/.gemini` surfaces only if those CLIs exist — no junk directories), registers hooks, runs the doctor. Skills already present as *symlinks* (managed by your own tooling) are never overwritten — skipped with a notice.
- **`hooks/install.sh`**: a missing `~/.claude/settings.json` is now created (fresh machines) instead of aborting.
- **Idempotency fix**: duplicate-detection markers matched the canon's directory name (`context-hooks/`), which differs in this distribution (`hooks/`) — re-running the installer used to add duplicate hook entries for external users. Markers now match by file name.
- **`hooks/doctor.sh`**: same directory-name fix for all checks, and the Orca-compatibility checks now run only when Orca is actually installed (`~/.orca/agent-hooks` exists) — machines without Orca get a clean pass instead of guaranteed failures; the machine-specific "≥11 entries" threshold replaced with a presence check.
- README (both languages): installation is now the single `bash install.sh` command; clone-relocation and symlink-skip behaviour documented.

## v1.3.0 — 2026-08-10

- **Any-depth hierarchies verified**: a live grandchild probe confirmed that every nesting level (child, grandchild, …) receives hooks with its *own* agent id and stores a flat transcript in the session's `subagents/` directory — so the guard measures every level individually. Added a `find`-based fallback for locating an agent's transcript in case the harness ever changes the directory layout.
- **Fleet rules extended**: the registry is kept by whichever level launches the wave (orchestrator — in the HANDOFF; a subagent running its own wave — in its progress file); a broken-off level is replaced by a successor that resumes from the registry and result files without re-asking for what was already received.

## v1.2.0 — 2026-08-10

- **Fleet rules** (orchestrator with dozens of subagents in flight): checkpoint a registry — "agent → task → result file → status" — into the HANDOFF *before* launching a wave; every agent's prompt must demand file output with a ≤15-line reply; at window thresholds launch no new waves, only receive. Rationale documented: a compaction mid-wait loses no data (results live in agents' files and transcripts, completion notifications reach even a compacted session) — the registry preserves the one thing that *was* at risk: knowing what is still pending and why.

## v1.1.2 — 2026-08-10

- README (both languages): the optional companion [pf-workflow](https://github.com/turvodnik/pf-workflow) now has a direct link and a concise "what it gives you" list (spec interrogation, self-contained task packets, proof-based acceptance, replanning, retros); the zero-config integration description kept.

## v1.1.1 — 2026-08-10

- Repository made public (read access by link); MIT license added.
- `statusline.sh`: the Orca script path now derives from `$HOME` instead of a personal hardcoded path (portability; on machines without Orca the call is simply skipped).
- README (both languages): standalone usage stated explicitly; pf-workflow described as an optional companion with automatic zero-config integration when present.
- Added `.gitignore`.

## v1.1.0 — 2026-08-09

- **Subagent-aware guard**: a subagent's tool calls are now measured against the subagent's *own* transcript and window (path derived as `<dir>/<session>/subagents/agent-<id>.jsonl`), under its own state key `agent-<id>.json`. Previously a threshold warning could be "swallowed" by a subagent (consuming the parent's `announced` flag) while reporting the parent's percentage — misleading for both sides.
- **Per-project thresholds**: `<project>/.agents/context-budget.json` with `{"thresholds": [a, b, c]}` (three ascending integers 1–99); missing/invalid → defaults 60/80/90. Zone semantics unchanged.
- **Critical fix — field separator**: hook input parsing switched from tab-separated to U+001F-separated fields. Bash `read` treats tabs as collapsible whitespace, so an empty field (e.g. absent `agent_id` on parent calls) shifted neighbouring values into the wrong variables and could silence the guard entirely for parent sessions.
- Docs: English is now the primary documentation language with a full Russian translation alongside (`README.md`/`README.ru.md`, `docs/rules-section.md`/`.ru.md`, this changelog); documented the pf-workflow companion tool.

## v1.0.0 — 2026-08-09

First release. Built and piloted in the owner's `optimize` project (pilot packets T-001…T-004, measured report lives in that project's repo).

- Rules "Context budget & session continuity": three memory layers, 60/80/90% window thresholds, "will it fit" heuristic, compactor instructions, human cheat sheet (`docs/rules-section*.md`).
- Skill `pf-handoff`: checkpoint/close with verification of proven results, full rewrite of the HANDOFF, ≤120 lines; template in `references/`.
- Skill `pf-resume`: pickup from the cheat-sheet in a new chat / after `/clear`; reopens a closed file by slug; auto-closes cheat-sheets of finished tasks.
- Hooks: `statusline.sh` (the `⛽ N% · Xk/Y` line + state file; Orca telemetry passed through when present), `context-guard.sh` (threshold injections + transcript fallback), `sessionstart.sh` (auto pickup after auto-compact with cheat-sheet self-repair; manual `/compact` → hint `/pf-resume <slug>` only; cleanup of state files older than 14 days), `precompact.sh` (manual/auto compaction log).
- `install.sh` (idempotent install into `~/.claude/settings.json` with backup, clone-relative paths) and `doctor.sh` (14 checks).
- Measured: harness cost ≈182 tokens/session worst-case; zero injections outside thresholds.
