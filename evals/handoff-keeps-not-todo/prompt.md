---
name: handoff-keeps-not-todo
description: |
  A checkpoint (pf-handoff) rewrites the active HANDOFF whole and must keep the
  «Не делать» section with both cancelled directions verbatim, while recording the
  new state. The prompt establishes that THIS session owns the task (pf-handoff
  step 1 refuses to rewrite someone else's file otherwise) and pins the file: «rewrite THIS
  file in place, do not create a new one» — the graders read a fixed path, and step 1's
  «or create one from the template» would otherwise be a legal 0/N (fix round 1).
  # anchor: AGENTS.md §13 (HANDOFF is the live task state; «Не делать» survives every rewrite) · pf-resume «Forbidden: resurrecting items from «Не делать»»
  No role body: pf-handoff is a skill of the plugin, invoked by the main session.
tags: [pf-handoff, smoke, handoff-keeps-not-todo]
runs: 1
max_turns: 30
timeout_seconds: 600
allowed_tools: [Read, Glob, Grep, Skill, Bash, Edit, Write]
---

Это моя сессия по задаче T-001, HANDOFF активный — `.agents/runtime/handoff/2026-01-12-readme.md`. Я только что закончил шаг: `bash tests/run.sh` → `3/3 passed`, коммит `abc1234`. Следующий шаг — обновить «Результат» в T-001. Сделай чекпоинт по pf-handoff (работа продолжается, сессию не закрываем): перепиши ЭТОТ файл целиком на месте — новый файл HANDOFF не создавай и старый не закрывай.
