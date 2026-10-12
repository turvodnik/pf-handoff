# Changelog

*[Русская версия](CHANGELOG.ru.md)*

Semver: breaking changes (HANDOFF file format, state file names, skill contracts, install scheme) = major; new features = minor; fixes = patch.

## [2.0.0] — 2026-10-12

Major by the semver rule above: the default window thresholds change from 60/80/90 % to 40/60/75 % and the per-project threshold file is no longer read (a configuration contract); `pf-handoff` no longer merges, pushes or deletes a branch when a session closes (a skill contract); the installer keeps a hook or status-line registration that points elsewhere instead of overwriting it (the install scheme).

### Breaking

- **Breaking: window thresholds are 40 / 60 / 75 % of the model's window** (were 60 / 80 / 90 %). At 40 the guard asks for a short HANDOFF checkpoint, at 60 for a full `pf-handoff` (and writes the state snapshot), at 75 for the final handoff. The only override is the environment variable `CONTEXT_GUARD_THRESHOLDS` — three ascending integers 1–99 separated by spaces, e.g. `"30 50 70"`; any other value silently falls back to the defaults. The status-bar colour zones follow the same values (yellow from the first, red from the second) and are no longer green < 60 % / yellow 60–79 % / red ≥ 80 %. Platform compaction stays outside the hooks: 80 % of a 1M window, 90 % of a 200k window (`/autocompact 800000`, `/autocompact 180000`).
- **Breaking: closing a session no longer integrates the branch.** `pf-handoff` step 6 used to merge the work branch `--ff-only`, remove its worktree and delete the branch. It now only records the branch, the worktree path, the HEAD SHA and "not merged, awaiting acceptance" in the HANDOFF; with uncommitted changes it stops. Merging, pushing and deleting are a separate explicit action with named preconditions (`skills/pf-handoff/references/branch-closing.md`).
- **Breaking: the installer keeps someone else's hook wiring.** `hooks/install.sh` used to point every registration — and the `statusLine` — at this clone. A hook or `statusLine` registration whose command names an existing file outside this clone (another copy of these hooks, a checkout of the author's workshop, your own status-line script) is now left as it is, with a line `KEPT: <event> → <path> (registered elsewhere; re-run with --force to point it at this clone)`. A `statusLine` command that names no file at all (`npx ccusage statusline`) is kept too. A word counts as a path only when it starts with `/`, `~`, `./`, `../` or `$` (`$HOME`/`${HOME}` are expanded). A registration on a missing file is still repaired. `bash install.sh --force` points everything at this clone. `doctor.sh` accepts a kept registration (rc 0) and names the path or the command. Coming from an older version: the old installer replaced your `statusLine`; the previous value is in the **earliest** backup `<settings file>.bak-<YYYYMMDD-HHMMSS>`, the one made before the first pf-handoff install (later backups already hold our line) — put the block back and re-run `install.sh`.

### Removed

- **The per-project threshold file `<project>/.agents/context-budget.json`** (v1.10.0 documented it in README, section "Configuration") is no longer read by `context-guard.sh` or `statusline.sh`; a leftover file is ignored. Use `CONTEXT_GUARD_THRESHOLDS`.

### Changed

- **`context-guard.sh`: subagents get no directives.** A directive told a subagent to checkpoint a HANDOFF that belongs to the task owner; 139 of 146 subagents ignored it. A subagent is recognised by the `agent_id` in the hook input or by its own transcript under `subagents/`; nothing is read or written for it.
- **`context-guard.sh`: the window comes from the model.** It is read from the model of the last reply in the transcript, not from the `/model` alias in the settings (with the alias `opus` the guard had taken 200k for a 1M model and announced a false "90 %"). The window the status line last reported (the harness's own number) is used first; with none, 1M is assumed for family 5 models; for any other model a window the guard guessed earlier, else 1M. `CONTEXT_GUARD_DEBUG=1` prints one line saying which window was used and where it came from.
- **`context-guard.sh`: a jump over the second threshold still writes the snapshot.** A single large tool result that took the context from 59 or 79 % straight to 95 % used to land in the last zone with no snapshot; the snapshot now follows the first crossing of the second threshold.
- **Fix: a turn with the server-side `advisor` tool read as a doubled context.** The API reports such a turn as several iterations (main model → advisor → main model) and the top-level usage is their sum — about twice the real context (one session: 515 357 → 1 033 942 tokens in one turn). The harness, the status line and the guard all read that sum, so the guard jumped from 51 % to "100 %" and skipped the second threshold. The guard now reads the last main-model iteration.
- **`precompact.sh`: foreign input is not ours to gate.** Input without a `"session_id"` key (garbage, another platform's payload) now exits 0 with no output and no log line; a Claude-shaped payload that cannot be parsed still blocks, as before. `autocheckpoint.sh` called without `--session` exits 0 silently, an empty `--session` stays an error. Every `OK` line of `compacts.log` now ends with `guard announced t2: yes|no|unknown`, so a retro can count compactions the guard did not see coming.
- **`sessionstart.sh`.** After a compaction (automatic or manual) and on resume the first line is "read the HANDOFF and continue": the agent's own file by `session_id`, else the newest one without a session id, with a list; the autopilot jobs still marked as running in its registry are listed. After a manual `/clear` it only points at the file (`/pf-resume <slug>`). On a fresh startup it only lists the active files, each with its `/pf-resume <slug>` pointer — whether to continue is the human's call; the registry jobs are to be checked, not assumed dead or alive. A session in a directory that is not a project (no `AGENTS.md`, no `.agents/`) gets a warning that snapshots and claims go to the global folders.
- **`installer`: a manually raised hook timeout survives a reinstall** (it was reset to 10 s on every `git pull && bash install.sh`).
- **`claims-check.sh`.** A claim may carry the session as `sid:<8 hex>` in the `who` field; `--sid <8hex>` (or `CLAIMS_SID`) turns an overlap with the same session's own line into `СВОБОДНО (своя)`, a malformed sid is `ВНИМАНИЕ`. `--sweep` reports expired claim lines (`--sweep --yes` moves them to `claims-archive.md`). The live check reads the whole file after its header and parses a `- ` list marker and the `СНЯТА` field the way the sweep does. A compound scope (`a + b`, `{a,b}`, `a, b`, a glob) is expanded into separate paths, each checked on its own. Every run appends one line to an event log next to the claims file (outside git; `CLAIMS_LOG` overrides the path).

### Fixed before release (independent QA of 2.0.0)

- **Installer: a foreign command in the same group as ours is kept (R1).** The upsert replaced the whole group around our command — a neighbour hook (say, an audit or secrets hook added next to ours) vanished silently and a narrowed `matcher` went back to `*`. Now only our command object is replaced, in place; the group's `matcher` and every foreign command stay. Our duplicate in a second group (from another clone) is removed. Inherited from v1.10.0.
- **Installer: a `'` in the clone path no longer breaks every hook (R2).** The path went into single quotes unescaped, so a clone under `Mike's tools` produced commands that were shell syntax errors with exit code 2 — every prompt and every compaction blocked. The quote is now escaped (`'\''`); `doctor.sh` and the installer read it back. Inherited from v1.10.0.
- **Installer: python3 is required and checked first (Y1).** With jq but no python3 the installer used to report a valid settings file as "invalid JSON" after the skills had already been copied. Now both `install.sh` and `hooks/install.sh` stop with "python3 is required" before writing anything. The hooks themselves still run with jq or python3.
- **Installer: an older pf-handoff clone is ours (Y2).** A registration pointing at `<dir>/hooks/…` of another pf-handoff clone (it has `install.sh` and `.claude-plugin/plugin.json` named `pf-handoff` — or, in v1.10.0 and older, `skills/pf-handoff/SKILL.md`) is moved to this clone with `MOVED: <event> <old path> → <new path>` instead of being KEPT; `doctor.sh` prints `WARN` for such a registration. A copy without that manifest (the author's workshop) stays KEPT.
- **`sessionstart.sh`: a list on startup, clipped fields (Y3).** On a fresh startup the hook no longer says "read the HANDOFF and continue" — a new chat may be about another task, and the file may belong to a parallel session or come from someone else's repository. Fields taken from the file (`task:`, registry cells) reach the context clipped to 120 characters.
- **`sessionstart.sh`: the session id is printed.** Every start, resume, compaction and `/clear` ends with `Сессия: <first 8 characters> — это значение поля session_id в HANDOFF/реестре`, so the agent can fill `session_id` in the HANDOFF and the registry; the template and the skill say where the value comes from.
- **Quiet mode for council children.** With `PF_COUNCIL_RUN=1` in the environment (pf-workflow's `council.sh` sets it for the CLI it starts) `sessionstart.sh`, `context-guard.sh`, `precompact.sh` and `statusline.sh` print nothing and exit 0; no snapshot is written for such a one-shot process.
- **The HANDOFF directory ignores itself in git (Y4).** When `pf-handoff.sh --path` or the snapshot hook creates `.agents/runtime/handoff/`, they put a `.gitignore` with `*` and `!.gitignore` into it — the snapshot holds the human's last turns verbatim and must not ride along with `git add -A`.
- **README (Y5, Y6):** the statusLine note points at the **earliest** settings backup; uninstalling removes only our entries with one command, instead of restoring a backup that would roll back every later setting; the skill copies in `~/.codex/skills` and `~/.gemini/skills` are listed.
- **`plugin.json` says 2.0.0 (Y7).**
- **No client project names in the shipped files (Y8).** Rules, hook comments and a test fixture name no longer mention them; `sync-from-tools.sh` and `tests/run.sh` check the tree against a private stop-list that lives outside this repository (`PF_PRIVATE_WORDS`; without it the test is skipped).
- **`context-guard.sh`: the status line's window beats the model-name rule (Y9).** A family-5 model can run with a 200k window; a stale state written by the status line now decides the window, and "family 5 ⇒ 1M" applies only when the state has no window. A window the guard guessed itself is stored with `window_guess: 1` and never mistaken for the status line's number.
- **`context-guard.sh`: a state file from v1.10.0 is not the status line's window (N2).** The old guard wrote its guess by the settings alias (200000 for `opus`) into the state with no mark, so after an update a session continued on a 1M model got a false final directive at 15 % real fill. The status line and the guard now write `state_version: 2`; a state without it counts as a guess (like `window_guess: 1`), and the family-5 rule applies.
- **The HANDOFF directory gets its `.gitignore` when it already exists, too (N3).** The snapshot hook and `pf-handoff.sh` put the self-ignoring `.gitignore` into an existing `.agents/runtime/handoff/` that has none (every project that ran v1.10.0 has the directory); an existing `.gitignore` is kept, a symlink in its place is not written through. README, "Update": how to untrack snapshots committed before.
- **Installer: another tool's hook with our file name is reported loudly (N4).** A kept registration of `precompact.sh`/`sessionstart.sh`/`context-guard.sh` with none of our scripts next to it prints `WARN: KEPT: … our <event> hook is NOT installed` (and `doctor.sh` gives `WARN`, not `OK`); a copy of these hooks (all four scripts together) stays a plain `KEPT`. `--force` prints `REPLACED: <event> <old command> → <our script>` for every registration it replaces instead of replacing it silently.
- **Rules: the claims protocol applies only where a claims file exists (Y10).** Without `CLAIMS_FILE`/`TOOLS` or the author's workshop the agent writes no claims and waits for no `ВНИМАНИЕ`; where the file is configured nothing changes. Workshop-only tools in the rules are marked as such; a fresh claims file needs a `## Живые заявки` heading (not just `touch`).

### Added

- **Milestone handoff.** `pf-handoff` rewrites the HANDOFF at five milestones, on every platform (a job summary accepted; a subagent or external process launched; before an external action — push, deploy, tag; end of a wave; before a long process): a short snapshot of about 10 lines below 50 % of the window, the full `pf-handoff` at 50 % or when the percentage is unknown. `skills/pf-handoff/scripts/pf-handoff.sh` helps agents without hooks: `--path` prints the active HANDOFF (creating one from the template if there is none), `--short` prints the short snapshot to fill in, `--touch` refreshes `updated:`.
- **`hooks/secrets-guard.sh`** — a `PreToolUse` hook on Bash that refuses a closed list of wide commands over secrets. The installer does not register it. It is a shim: when `pf-guard/hooks/secrets-guard.sh` is present (`PF_GUARD_HOME`, or `repos/pf-guard` next to this clone) it runs that file, otherwise it runs its own body.
- **Rules (`docs/context-rules.md`, both languages):** what may be written to MEMORY.md (only the human's words or the agent's own conclusion, never a tool result, never identifiers), the cross-project solutions index, the session start/finish ritual, command provenance and the rule against rolling back others' work on suspicion, the claims protocol above, and the compaction levels per window size.
- **`evals/`: 3 contract cases** for `claude plugin eval` (`handoff-keeps-not-todo`, `resume-refuses-not-todo`, `resume-stops-on-stale-handoff`), each anchored to a rule of the skill text, with fixtures from a `scaffold.sh`, free graders and a negative control. `evals/README.md` records the first full run (3/3 cases, 18 sessions, Δ 0 / +0.11 / 0): the cases do not discriminate the rule text — documented, not fixed. `.claude-plugin/plugin.json` is a manifest for `claude plugin validate`/`eval` only; it declares no `hooks`, so `install.sh` stays the install path.
- **README:** an "Update" block (`cd <clone> && git pull && bash install.sh`), the `KEPT`/`--force` explanation, the settings-backup note for those who installed a version before 2.0.0, and a "For your AI agent" section — exact install, check, update and first-use steps an agent can follow without guessing.
- **Tests:** `tests/guard-cases.sh` (window from the model, advisor correction, subagents silent, first crossing of the second threshold), a rewritten `tests/threshold-parity.sh`, extended claims-check probes, installer cases for KEPT/`--force`/timeout, and `actionlint` as an optional CI piece.

## v1.10.0 — 2026-08-14

A snapshot before every compaction, and a protocol for sessions that cannot see each other. Minor, not patch: two genuinely new capabilities ship here — the compaction gate and the write-claim check — while the HANDOFF format, the state file names and the install scheme are untouched (this project's own bar for major).

- **New: an automatic snapshot, and a gate that will not let compaction happen without one.** `autocheckpoint.sh` (new hook, called — not registered) writes `<project>/.agents/runtime/handoff/<date>-auto-<session>.md` from facts visible on disk: branch, uncommitted changes, last commits, open task packets, live HANDOFF files, the last human turns of the transcript, window fill. `precompact.sh` calls it before **every** compaction — automatic and manual `/compact` alike — and returns exit code 2, documented as "blocks compaction", when nothing could be written anywhere. `context-guard.sh` does the same at threshold t2 (80% by default, following the project's `context-budget.json`) and tells the agent the **fact** — snapshot written, or not. The snapshot is a safety net, not `pf-handoff`: a script cannot tell what is proven from what is claimed, so the meaningful checkpoint stays the agent's job.
- **The price of that gate, said out loud** (and now written in the docs, both languages): it can block compaction — a hard stop, not a warning. It fires when the snapshot could not be written to the project directory *or* to the emergency directory `~/.claude/context-state/handoff`, when `autocheckpoint.sh` is missing next to `precompact.sh`, and when neither `jq` nor `python3` is on PATH — with no JSON reader there is no session id, so there is nothing to name a snapshot after. Ways out, in order: run `pf-handoff` by hand, fix write permissions, install `jq` or `python3`, or — last resort — remove the `PreCompact` entry from `settings.json` and lose the safety net with the block. Every attempt is logged (`~/.claude/context-state/compacts.log`), and the reason always goes to stderr.
- **Compaction itself is the harness's job, and `doctor.sh` now says which mode you are in.** A hook cannot start compaction — no such output field exists — so the "compact at 80%" half of the design is the `autoCompactWindow` setting, counted in **tokens, not percent**. `doctor.sh` reports its value, or reports that compaction happens at the model's limit. Never a failure, just the fact.
- **New: write claims for parallel sessions, with a real check instead of a snippet.** Sessions do not see each other's commands, and "I see no basis for this edit" is not proof there is none. Claims live in one machine-local file; `skills/pf-handoff/scripts/claims-check.sh` answers in exactly three states — `ЗАНЯТО` (1), `СВОБОДНО` (0), `ВНИМАНИЕ` (2, "could not check") — and never with silence. Both sides of a comparison are canonicalized for real (expanduser → absolutize → realpath → NFC → case folding, the last only when the volume actually is case-insensitive), because one path has many spellings and string comparison silently missed them. The script ships with its own hostile battery, `tests/claims-check-probes.sh` (54 probes), carried across by `sync-from-tools.sh`.
- **Fix: HANDOFF pickup on session start worked on macOS only.** `sessionstart.sh` read modification time with BSD `stat -f %m`; on Linux that is a different program with the same name, every file dropped out of the list, and the result looked exactly like "no live HANDOFF files". It now tries the BSD form, then the GNU one (`stat -c %Y`), and validates the **result** rather than the exit code — GNU `stat -f` "succeeds" while printing filesystem information.
- **Fix: closing a branch no longer guesses who owns a worktree.** When `orca worktree list` itself failed, the pipeline returned `grep`'s status, not Orca's, so the failure read as "unmanaged" and `git worktree remove` deleted a managed worktree behind Orca's back. The reference now stops and says ownership is unknown — a fourth state, fail-closed, instead of a plausible guess.
- **The suite tells the truth about the gate again — and gained a group.** The old "hooks never crash" matrix demanded a silent `rc=0` from `precompact.sh` on garbage stdin, which the gate deliberately contradicts. `precompact.sh` moved to its own group asserting the stricter contract: blocked **and** loud (exit 2 plus a human-readable reason) when no snapshot could be written; silent `rc=0` plus a snapshot on disk when one could; and a negative control — the same valid payload into a read-only `HOME` must go red. `drift-check.sh` level 1 (this repo against a fresh `sync-from-tools.sh`) also runs as part of the suite.

Findings of the independent pre-release QA, all closed before the tag:

- **Fix (critical): on Debian/Ubuntu every hook was dead, and the new gate blocked every compaction.** The installer registered the hooks as `/bin/sh '<hook>'`. Claude Code runs that command through the system shell, so the `#!/bin/bash` shebang never applied: on macOS `/bin/sh` *is* bash and nothing showed, but on Debian/Ubuntu it is dash, which cannot read these scripts — each hook died on the first bash-ism with exit code 2. And 2 is not "did nothing": for `PreCompact` it means "compaction blocked", for `UserPromptSubmit` "prompt blocked and erased". The registration now names the interpreter explicitly (`bash '<hook>'`, found on `PATH`, so a Homebrew- or Nix-only bash works too); with no bash at all the wrapper drains stdin and exits 0 — the hooks self-disable rather than wedge the session. Hooks were **not** rewritten to POSIX: they are 1500 lines of bash whose every future edit would have to stay POSIX with nothing on macOS able to notice, while naming the interpreter is one word and cannot regress.
- **Fix: the documented update path (`git pull && bash install.sh`) used to repair nothing.** The installer only ever *added* a missing entry, so a machine that already had the old registration kept it forever — the fix above would not have reached a single existing user. It now replaces its own outdated entries (matched by hook file name) and still never touches a foreign one; a second run is byte-identical as before.
- **Fix: `claims-check.sh` answered a calm "no holdings" from a root it had no business trusting.** Called through the documented `~/.claude/skills/pf-handoff/scripts/…` path — where the installer puts plain copies, not symlinks — the "four levels up" rule computes the workshop root as `$HOME`; with a `~/.agents/runtime` directory present, the calm branch fired over a root that was simply wrong. The derived root is now *checked* (a `skill-library/` directory must sit at it) and otherwise answers `ВНИМАНИЕ` naming the fix: set `TOOLS` (or `CLAIMS_FILE`) once. The docs no longer promise "found without configuration" outside the workshop.
- **Fix: `sessionstart.sh` silently lost the HANDOFF pickup with no `HOME` in the environment.** Under `set -u` a bare `$HOME` killed the script, the wrapper swallowed the error, and the outcome looked exactly like "no live cheat-sheets". It now uses `PF_EFFECTIVE_HOME` like the other three hooks — the v1.9.0 contract this one hook had missed.
- **Fix: an empty payload passed compaction with no snapshot *and* no trace.** It still passes (blocking on "stdin never arrived" would recreate the Debian wedge above), but the attempt is now logged as `SKIPPED-empty-stdin`. A subagent session — a deliberate no-snapshot case — is logged as `SKIPPED-subagent` instead of the old `OK ?`, which read as "snapshot written".
- **The block message is English now** (with a one-line Russian summary), and no longer cites an internal rule number that appears nowhere in this distribution. README, both languages, describe the gate at last: what it does, when it blocks, what you see, and the four ways out — until now README still described the v1.9.0 hook that "logs every compaction", the one document a new user reads first.
- **New test group closing the blind spot that hid all of this**: the suite now takes the command string **out of a `settings.json` the installer just wrote** and executes it with a real POSIX shell (`/bin/dash`, or `/bin/sh` where that is dash — on `ubuntu-latest` CI it is). Every other group starts hooks with an explicit `bash`, which is exactly why a green CI matrix on ubuntu proved nothing about the way hooks actually run. Plus the negative control: the old wrapper under the same shell must go red (it exits 2), and probes for the stale-entry upgrade and for the `HOME`-less HANDOFF pickup.

Verified: `bash tests/run.sh` — **50/50 GREEN** in a dev clone; **49/49 GREEN + 1 SKIP** in a plain clone of this repo (the `drift-check` group needs the author's `_tools` canon and honestly skips without it). `bash tests/threshold-parity.sh` — 19/19 GREEN. `tests/claims-check-probes.sh` — 54 probes, 0 failed.

## v1.9.0 — 2026-08-13

The `PF_EFFECTIVE_HOME` contract, three-state branch closing, plus a test suite that watches its own back. Minor, not patch: the new `bash tests/run.sh` + CI is a genuine new capability, not a fix, and nothing here renames a state file, changes the HANDOFF format or the install scheme (this project's own bar for major).

- **`$HOME` itself is never reassigned again (F-20).** `statusline.sh`, `context-guard.sh` and `doctor.sh` used to patch the real `$HOME` in place when it was unset (falling back to `$TMPDIR`); each now computes a separate `PF_EFFECTIVE_HOME` and reads/writes state through that instead. Every effective path stays the same — nothing a caller observes changes — but downstream code (a child command, a future edit to these scripts) can no longer mistake the fallback directory for a real home by reading `$HOME` directly.
- **Branch-closing worktree removal is three states, not two.** The old `A && B || C` one-liner silently fell back to `git worktree remove` whenever `orca worktree rm` itself failed for an Orca-managed worktree — deleting the worktree while its Orca card survived, pointing at nothing. The reference now spells out three states: no Orca on the machine, or an unmanaged worktree (both: plain `git worktree remove`, same as before), and an Orca-managed worktree where Orca's own removal command fails (stop and diagnose — never fall back to git).
- **New: `bash tests/run.sh` + GitHub Actions CI.** One command runs `bash -n` and ShellCheck on every hook, validates the workflow YAML, re-runs `threshold-parity.sh` (statusline/guard zone parity, T-014/F-20), a 24-case hooks-never-crash matrix, `install.sh` idempotency and `doctor.sh` against a minified `settings.json`, plus two negative controls (a mutated hook or a mutated threshold must turn its own check red). Portable `mktemp` in the harness itself — a BSD-only `-t <prefix>` form silently no-ops the negative controls on `ubuntu-latest`'s GNU coreutils, found and fixed before this shipped. README (both languages) gets the CI badge and a one-line "how to run it locally". Fix round (same day, before tagging): the workflow-YAML check now SKIPs, not FAILs, when `python3` has no PyYAML module — it used to blame a valid `tests.yml` for a missing third-party module on the exact stock configuration (`python3` present, PyYAML absent) that ships on `ubuntu-latest` and on macOS's Command Line Tools.
- `sync-from-tools.sh` now carries `tests/threshold-parity.sh` across on every sync, adapting its one `HOOKS_DIR` line automatically — it used to be a manual, easy-to-forget transplant (the same rsync filter that deliberately keeps `context-hooks/tests/` out of `hooks/` also meant the file never reached `tests/` either, until now).

Verified: `bash tests/run.sh` — 34/34 GREEN.

## v1.8.2 — 2026-08-12

Documentation-only patch, closing the last notes of the v1.8.1 QA:

- README (both languages): the two "three conditions" phrases referred to two different triples; there are in fact four conditions, and both places now name the same four.
- Skill step 2a no longer overstates step 6, which applies only to a session that worked outside the main branch.

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
