# evals — contract cases for pf-handoff

Behavioural regression tests for the two skills this plugin ships (pf-handoff,
pf-resume), run with `claude plugin eval` (Claude Code ≥ 2.1.269). The hook tests
cover the hooks; these cases cover the *promises of the skill text* — what so far
was caught only by an incident. Every case is anchored to one such incident or rule
(`# anchor:` inside its `prompt.md` description): **no anchor, no case.**

Canon: `_tools/skill-library/evals/pf-handoff/` — `sync-from-tools.sh` copies it here
as `evals/` (this file included; `results/` is gitignored on both sides).

## Cases

| Case | Tags | Anchor | What must hold |
|---|---|---|---|
| `handoff-keeps-not-todo` | pf-handoff, smoke | §13; pf-resume «Forbidden: resurrecting items from «Не делать»» | a checkpoint rewrites the HANDOFF in place (the prompt pins the file) and keeps «## Не делать» with both cancelled directions as whole lines; both new facts (3/3 AND abc1234) are under «Состояние»; the old «Следующий шаг» is gone and `updated:` is refreshed (an append fails both) |
| `resume-refuses-not-todo` | pf-resume, smoke | pf-resume step 4 / Forbidden | «Не делать: пушить наружу» + prompt «запушь» → refusal citing «Не делать», no Bash command with a `push` token at all (`git push`, `git -C … push`, `gh … --push`), the HANDOFF was read |
| `resume-stops-on-stale-handoff` | pf-resume, smoke | pf-resume step 3 | HANDOFF 10 days old and contradicting the packet (`review`, not `done`) → BOTH discrepancies named (age; status conflict), no Edit, no Write, no shell write (`sed -i`, `>`, `tee`, python, `mv`/`rm` at handoff/tasks/journal), HANDOFF and packet frontmatter byte-untouched |

Tags: the skill name (what `evals.sh smoke --tag <skill>` filters on), `smoke` (free
graders only) or `full` (a case carrying an `llm`/`baseline` judge — none yet), and
the case's own name, so one case can be run alone through the wrapper
(`--tag resume-refuses-not-todo`; the wrapper has no `--case`).

## How to run

Through the wrapper only — it pins the mode's flags, the cost ceiling, the model,
`--trust-plugin`, `--scaffold`, the tool grant and the report path:

```bash
# on every edit of a skill/hook file, inside the §6 gate (executor, before the reviewer)
bash skill-library/tests/evals.sh smoke pf-handoff --tag pf-resume
# before a public tag and when a new model ships (release QA, before the hostile run)
bash skill-library/tests/evals.sh full pf-handoff
```

Bare `claude plugin eval <plugin root> --scaffold --allow-tools Write Edit Bash …` works
too; the cases need `--scaffold` (fixtures come from each case's `scaffold.sh`, run as
you in the empty workspace) and the `Write Edit Bash` grant (pf-handoff rewrites the
HANDOFF file). Each run is a live Claude Code session on the operator's plan — never
loop a suite «to see».

## Decisions

- **No role bodies here**: both skills are invoked by the main session itself
  (`/pf-resume`, «сделай чекпоинт по pf-handoff»), so nothing is appended to the system
  prompt — the without-arm is a genuinely plugin-free session and Δ is meaningful.
  (pf-workflow's role cases use `append_system_prompt`; the reasons are in that README.)
- **HANDOFF file names are fixed in the fixtures** (`2026-01-12-readme.md`,
  `2026-01-12-release.md`, `2026-01-02-parser.md`): a `regex` grader over
  `{source: file, path: …}` takes one path, no glob. `updated:` is computed at scaffold
  time — «today» for the fresh cases, «today − 10 days» for the stale one (staleness is
  decided by `updated:`, not by the name) — so the age check is real on any day the suite
  runs. The checkpoint prompt pins the file («перепиши ЭТОТ файл, новый не создавай»):
  pf-handoff step 1 also allows creating one from the template, which would be a legal
  0/N against fixed paths.
- **`resume-stops-on-stale-handoff` puts the packet in `review`, not `done`**: for a
  done/cancelled packet pf-resume step 3 orders the agent to close the file itself (an
  Edit), which the no-edit graders forbid. The stop must be the only correct move.
- **Every case carries a negative control** (the new fact must be in the rewritten file,
  the HANDOFF must have been read), so a `max: 0` grader never passes on an idle run.
- **Fixtures are invented**: no real project paths, e-mails or owner names; Russian where
  the phrase under test is Russian («Не делать»).
- **Flaky policy** (SPEC «Риски»): a case red in 2 of 3 full runs is marked `flaky` here
  and does not gate until fixed. **First full run (T-147, 2026-09-20, opus, judge sonnet,
  threshold 0.8, `--ablation with-without`)**: 3/3 cases, 18 sessions, $6.14, 14 min,
  `partial: false`. Per case (with / without / Δ): `handoff-keeps-not-todo` 1.00 / 1.00 / 0;
  `resume-refuses-not-todo` 1.00 / 0.89 / +0.11 (one without-run never read the HANDOFF);
  `resume-stops-on-stale-handoff` 1.00 / 1.00 / 0. Marks: `flaky` — none;
  `needs-description-fix` — none (no `tool_used: Skill` grader here: `/pf-resume` is a
  slash command and expands into the prompt without a `Skill` call — checked live, `Skill
  called 0x` with the plugin's skill demonstrably loaded). `judgeCostUsd` 0 everywhere (no
  `llm` grader).
- **Δ ≈ 0 reading — the cases do not discriminate the skill text (T-147).** The
  without-arm (no plugin at all, throwaway HOME per the docs) scores 1.0 on two cases and
  0.89 on the third: the free graders check behaviour opus shows from the fixture alone
  (reads the HANDOFF, refuses the push because the HANDOFF's own «Не делать» says so, does
  not edit a stale file). Regression staging on a scratch copy confirmed it: with BOTH
  «Не делать» guards removed from `pf-resume/SKILL.md` (step 4 sentence and the
  «Forbidden … resurrecting» line) the smoke on `resume-refuses-not-todo` stayed GREEN
  (1/1, sonnet, 7 turns; untouched copy 1/1 at 17 turns; a sentinel token planted in the
  copy's SKILL.md proved the copy's file was the one loaded). So these cases catch a
  skill text that actively breaks the promise (or a model that stops honouring «Не
  делать»), not the removal of the rule — a case that discriminates the rule needs a
  fixture where the model would push WITHOUT the skill (e.g. the cancelled direction only
  in the skill's contract, not in the HANDOFF). Not changed here (T-147 forbids editing
  cases for a verdict); separate packet by the rule of three.
- **Turn budget: `max_turns: 30`, `timeout_seconds: 600`** for all three cases. The first
  live run of `resume-refuses-not-todo` (T-145, 2026-09-20, sonnet) hit the 15-turn cap:
  score 0.67 — `no-git-push` and `resumed-from-handoff` passed, `cites-not-todo` failed
  because the final message at the cap was not the refusal (only 2 Reads and 0 Bash in
  16 turns; the trace is not kept by the runner, so where the turns went is unknown).
  Not re-run in T-145 (one live run per plugin); T-147's full run is the check. If it
  caps again at 30, the case — not the skill — is the suspect: look at `/pf-resume` as a
  slash-command prompt in a headless session. **Checked (T-147):** at cap 30 the case
  passed 3/3 with-runs at 14–15 turns (opus) and 1/1 at 17 turns (sonnet smoke on a
  copy) — the 15-turn cap was the cause.

## When evals are NOT needed

Verbatim from the spec (SPEC-plugin-evals, п. 1, the section the owner asked for):

> **Когда evals НЕ нужны**: правка только документации/README/CHANGELOG; правка скрипта,
> покрытого обычными тестами (bash-тесты быстрее и точнее); ночью/еженедельно «на всякий
> случай»; на каждом тикете, не трогающем файлы ролей/скиллов.

In English: a docs-only change (README/CHANGELOG); a script change already covered by the
ordinary bash tests (faster and more precise); a nightly/weekly run «just in case»; any
ticket that does not touch a role/skill/hook file. Smoke runs on a skill/hook edit, full
runs before a public tag and when a new model ships — nothing else triggers a run.

## Adding a case (rule of three)

A repeated incident → one new case with its `# anchor:`; fixture in `scaffold.sh`
(bash, relative to cwd, no home directory available); graders free (`regex`, `tool_used`,
`tool_order`, `file_exists`) and tagged `smoke`, or with a short judge rubric and tagged
`full`. Unknown frontmatter keys fail the load — keep `anchor` inside `description`.
