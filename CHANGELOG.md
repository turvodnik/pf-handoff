# Changelog

*[Русская версия](CHANGELOG.ru.md)*

Semver: breaking changes (HANDOFF file format, state file names, skill contracts, install scheme) = major; new features = minor; fixes = patch.

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
