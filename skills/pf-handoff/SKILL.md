---
name: pf-handoff
description: Чекпоинт или закрытие сессии — зафиксировать состояние, ничего не потеряв. Checkpoint or close a session — reconcile what is proven, rewrite the live HANDOFF state file (§13), statuses and journal. NOT for handing work to another agent or worktree (that is orca-cli/orchestration). Use when the context window is running out, «сохрани состояние сессии», «сделай чекпоинт», «/pf-handoff», перед /compact или /clear, save session state.
---

# pf-handoff — capture the state, losing nothing

Always communicate with the user in the user's language (Russian in the origin system). The HANDOFF file, its section names, journal and status formats stay exactly as written below.

The live task state is the project's HANDOFF file `.agents/runtime/handoff/YYYY-MM-DD-<slug>.md` (§13). The skill rewrites it whole: fresh, precise, no residue. Two modes: **checkpoint** (work continues) and **close** (session ends). Full context-budget rules (memory layers, window thresholds, subagent swarms, human cheat-sheet) — `references/context-rules.md`.

## Steps

1. Pick the file: the active HANDOFF of this task (`status: active`), or create one from `references/handoff-template.md`; slug — ticket number or topic. If this session did NOT work the task and the active file belongs to another task/session — that is not a checkpoint: report what you found and ask before rewriting someone else's file (§13: the owner writes, others read).
2. Reconcile before writing: list what is DONE and how it is proven (command output, test, commit — §11). Unproven items do not go into «Состояние» — they go to «Следующий шаг» or «Блокеры».
3. Rewrite the file WHOLE per the template, ≤120 lines: Цель / Состояние / Следующий шаг / Блокеры и вопросы / Ключевые файлы и решения / Не делать. Anything stale from the previous version — one line in «Не делать», or out.
4. Refresh `updated` in the frontmatter and the statuses of the affected task packets (§9).
5. Close (session ends, or the human asked): `status: closed`, journal entry §10 (decisions and the handoff, not diffs), then one line to the human on how to continue: same chat — just continue; new chat — `/pf-resume <slug>`; terminal closed — `claude --continue`.
6. Closing while the session worked outside the main branch — close the branch per `references/branch-closing.md` (merge `--ff-only`, remove the worktree, delete the branch). Anything off (divergence, uncommitted changes, `-d` refuses) — delete nothing, report to the human.

## Forbidden

Appending instead of rewriting; exceeding 120 lines; unproven claims in «Состояние»; retelling tasks already closed in the journal (the journal is the source — HANDOFF gets one line with a pointer); inserting secret values (§5); committing HANDOFF to git (the directory is in .gitignore — long-term history lives in the journal).
