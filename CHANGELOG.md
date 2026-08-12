# Changelog

*[Русская версия](CHANGELOG.ru.md)*

Semver: breaking changes (HANDOFF file format, state file names, skill contracts, install scheme) = major; new features = minor; fixes = patch.

## v1.8.1 — 2026-08-12

Discretionary findings of the v1.8.0 independent QA, all closed:

- `context-guard.sh` used to switch itself off silently when `HOME` was unset, while `statusline.sh` has had the fallback since v1.5.0 — the only input on which the two hooks disagreed. Both now fall back to `TMPDIR`.
- The no-`jq` branch printed its directive with `\uXXXX` escapes: valid JSON, but the text is meant to be read by a human and an agent.
- `doctor.sh` judged `settings.json` only through `python3` and reported "invalid or missing" on a machine that has `jq` — contradicting the README, which promises either one is enough. It also counted matching *lines* rather than occurrences, so a single-line `settings.json` produced a false "not registered".
- Step 2a no longer contradicts step 6: it is named as the exception path (the normal place for a review is before the commit, pf-do step 5a), and the exit code 1 of the companion script is spelled out as "not reviewed", never "clean".
- README (both languages) now states that with pf-workflow, the Codex CLI and project consent all present, closing a session may call a paid third-party CLI — and that missing any of the three means the step is skipped silently.

## v1.8.0 — 2026-08-12

Threshold parsing fixed, plus an optional Codex pass on closing:

- **Fix: the status bar and the guard now share one threshold contract.** With a fractional `.agents/context-budget.json` (e.g. `[59.5, 79.5, 89.5]`) the status line floored the values and coloured the bar at 59/79, while `context-guard.sh` rejected the same config and kept firing at 60/80/90 — the colours did not mark where the directives actually arrive. The status line also accepted thresholds out of order or out of range (`[90, 5, 3]`, `[50, 70, 100]`), which the guard refuses. Both sides now require exactly three integers 1–99 in ascending order, silently defaulting otherwise.
- **Fix: two divergences inside the parsing itself.** Thresholds were joined with a space and split unquoted, so a value like `"60 70"` inside the JSON became two fields and passed validation the guard rejects — the separator is a tab now. And in the no-`jq` branch the guard converted values with `int(x)`, accepting `[1.0, 80, 90]` that its own jq branch refuses; it emits `str(x)` now, with the integer check left to the shell. All four parsing branches follow the same contract.
- **New: step 2a — an optional Codex pass over uncommitted code when closing a session.** Runs only if the pf-workflow companion ships `pf-do/scripts/codex-review.sh` and only when the tree still holds uncommitted *code*; without Codex or that script the step is skipped silently. Findings do not become work — a leaving session fixes nothing; the report path and one digest line go into «Следующий шаг» so the next session starts with the remarks in hand.

Verified: the live `statusline.sh --preview` against the guard's reference parsing on 9 cases (fractional, ordering, range boundaries, numeric strings, null) — the bar now changes colour exactly where the guard accepts the thresholds; previously 5 of the 9 diverged. The first two of these defects were found by a Codex review, and two more by a Codex review of the fix for the first.

Independent QA before release found one more divergence, now fixed: the guard accepted string thresholds carrying a space or a sign (`[" 50", "+50", ...]`) that the status line rejects — `test -ge` tolerates them, and the digits-only filter existed on one side only. Two more alignments came with it: the project directory is now resolved by the same formula in both hooks (`workspace.current_dir`, then `cwd`; the guard used to read only `cwd`, so the two could read different config files), and a config with a UTF-8 BOM no longer breaks the no-`jq` branch. Verified on 13 threshold cases against the live status line.


## v1.7.1 — 2026-08-12

English follow-up (discretionary findings of the v1.7.0 independent QA):

- `install.sh`, `hooks/install.sh` and `hooks/doctor.sh` speak English — messages and comments; logic unchanged (sandbox install re-verified: clean run, doctor green).
- `docs/rules-section.md` gains a note that older doc versions showed the HANDOFF section names in English translation while the shipped behavior always used the Russian template literals.

## v1.7.0 — 2026-08-12

Skills rewritten in English, startup-cost diet for the rules, plus an `effort` status-bar widget:

- **Skills are now English.** `pf-handoff` and `pf-resume` instruction bodies (and the skill-shipped `references/`) are rewritten in English — ≈35% fewer tokens on every skill load, and readable by the international audience. Behavior contracts are unchanged: the HANDOFF section names, statuses and journal formats stay exactly as before (they are protocol, and the origin system's artifacts are Russian); the artifact template `references/handoff-template.md` deliberately stays Russian — replace it with your language if needed. The skills now instruct the agent to answer in the user's language.
- **Descriptions lead with a Russian one-liner.** Each skill's `description` opens with a short Russian phrase ("what and why") before the English text: the origin system's human reads the skill list with his eyes, and after the English rewrite that list stopped speaking his language. Trigger phrases — English and Russian alike — are unchanged, and nothing in the skill logic depends on the leading phrase: forking this for a monolingual setup means deleting it, nothing more.
- **Rules split by cost.** `docs/rules-section.md` (and `.ru.md`) — the section you paste into CLAUDE.md/AGENTS.md — is now short: only the invariants that must hold with no skill loaded (memory layers, thresholds 60/80/90% + per-project override, the fleet-registry rule, compactor instructions). Everything else moved to `references/context-rules.md`, which ships with the `pf-handoff` skill and is read on demand. **No rule was dropped** — every rule from the old section survives in the pair (verified fragment by fragment by independent QA), and the compactor instructions deliberately stay inline (they only work if they are in context at compaction time). Saving: ≈600 tokens off every session start for the English section, roughly twice that for the Russian one.
- `docs/context-rules.md` / `docs/context-rules.ru.md` — the full rules as human-readable docs (English + Russian), mirroring the skill's reference. The English file is generated by `sync-from-tools.sh` from the now-English canon (three copies of one text drift otherwise); the Russian one is a hand-kept translation, with the sync script warning when the section counts diverge.
- `pf-resume` now points at the full rules too — a session picked up after `/clear` is no longer left with the short section alone.
- **New `effort` widget** — the model's reasoning-effort level (`low`/`medium`/`high`/`xhigh`/`max`) from the CLI's `effort.level` field; unknown or absent values hide the widget. It is **on by default** in line 1 (`model, effort, context, branch`). To keep the previous look, set `"line1": ["model", "context", "branch"]` in `~/.config/pf-handoff/statusline.json`. On CLIs that do not report the field the render is byte-identical to v1.6.2.
- `examples/statusline.json` updated to the new default.

**Upgrading:** re-paste `docs/rules-section.md` over your existing §13 section (or keep the old one — the skills work with both; you just keep paying the tokens). The skills must be reinstalled (`bash install.sh`) so `references/context-rules.md` lands next to them.

## v1.6.2 — 2026-08-11

Skill-contract fix after a live field report (a fresh empty session ran `/pf-handoff` and silently rewrote the initiative's active HANDOFF, folding in full retellings of tasks already closed in the journal):

- `pf-handoff` step 1: a session that did no work and finds an active HANDOFF belonging to another task/session must NOT rewrite it — report what was found and ask first (§13: the owner writes, others read).
- "Forbidden" gains: no retelling of tasks already closed in the journal — the journal is the source; the HANDOFF gets one line with a reference at most.
- Verified behaviourally: a fresh agent given the exact field scenario now quotes the guard clause, declines the rewrite, and keeps closed tasks to one line.

## v1.6.1 — 2026-08-11

Config DX (the "middle ground" instead of a TUI configurator):

- `bash hooks/statusline.sh --preview` — instant two-line render with sample data (and your real git branch): edit the config, re-run, see the result; no Orca calls, no state writes.
- `hooks/doctor.sh` now validates the status-bar config: a present-but-broken JSON is a loud FAIL with a diagnostic hint — no more silent fallback mystery; absent config is an explicit OK.
- `examples/statusline.json` — a copy-ready config reproducing the default look; quick-start block in both READMEs.
- Independent mini-QA before the tag: 24/24 checks passed, no findings.

## v1.6.0 — 2026-08-10

- **Configurable status bar** — `~/.config/pf-handoff/statusline.json` (optional; defaults reproduce v1.5.0 exactly): `line1`/`line2` widget layout from a whitelist (`model`, `context`, `branch`, `session`, `weekly`, plus new `cost` and `duration`), `bar_width` (5–60), `bar_filled`/`bar_empty`, `separator` (empty string honoured), `colors: false` for plain text. An absent `line1`/`line2` key keeps the default; an explicitly empty array disables that line. Bar zone colours follow the *project* thresholds from `.agents/context-budget.json`. Full reference in both READMEs.
- Hardened by independent QA round #2 (80 checks; findings fixed before the tag, per the release rule): octal-looking numbers ("08") no longer blank the render or drop state; user bar characters go through `ENVIRON` (no awk escape/format interpretation); FIFO configs can't hang any hook (regular-file checks everywhere); comma-in-name whitelist bypass closed; widget-name globbing disabled; BOM configs parse identically in jq and python3 branches; absurd `duration` values hide the widget instead of showing negatives; fractional project thresholds floor consistently in both engines.

## v1.5.0 — 2026-08-10

- **Rich two-line status bar** (ccstatusline-style, still zero dependencies — pure bash/awk): context progress bar with zone colours matching the §13 thresholds, tokens/window, git branch with session line counts, and a second line with subscription rate limits — `Session % | Reset | Weekly % | Weekly Reset`. Segments degrade gracefully when a field is absent; the Orca passthrough and the state-file sensor are unchanged.
- Hardened per the independent QA round (82 scenarios, 7 findings fixed before release, per the release rule): non-numeric `used_percentage`/window values no longer blank the output or drop the state file; scalar `.model`/`.rate_limits`/`.workspace` no longer break the jq path; guaranteed exit 0 even without `$HOME`; control-character injection (ANSI/U+001F/newline) via payload strings is stripped at the extractor; over-long session ids no longer leave tmp litter; an unreadable previous state no longer resets `announced`; percentages use a dot regardless of locale.

## v1.4.2 — 2026-08-10

Fixes from an independent adversarial QA round (64 scenarios; full credit to the findings):

- **announced survives statusline refreshes** (major): the statusline rewrote the session state without the `announced` field, so in a real terminal every refresh reset "already announced" and the guard re-issued the same threshold directive over and over. The field is now carried over on every rewrite.
- **Installer never deletes foreign data**: a pre-existing real directory named like our skills is replaced only if its SKILL.md carries our `name:`; anything else is skipped with a notice (previously silent `rm -rf`).
- **Dotfiles-friendly**: a symlinked `~/.claude/settings.json` is edited through its target — the symlink stays a symlink.
- **Frontmatter-strict pickup**: `status: active` inside a file body can no longer revive a closed HANDOFF — only the frontmatter counts.
- **Path hardening**: `session_id`/`agent_id` from hook input are sanitized before being used as file names (a crafted `../evil` id could write outside the state directory).
- Cosmetic: installer's before/after counters no longer print a stray zero on a fresh settings.json.

## v1.4.1 — 2026-08-10

- **Fix**: a HANDOFF file created from the template *as-is* was invisible to the SessionStart hook — the template's frontmatter carried an inline comment (`status: active   # active | closed`) while the hook's pattern required the line to end right after "active". The pattern now tolerates trailing comments, and the template frontmatter is comment-free. Found by the standalone-install test (12/12 green after the fix).

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
