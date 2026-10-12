#!/usr/bin/env bash
# Fixture for handoff-keeps-not-todo: a project with an ACTIVE HANDOFF whose
# «Не делать» section holds two cancelled directions, plus the packet it
# points at. `updated:` is today (computed) so the file is not stale; the
# file NAME is fixed because graders read it by path. Runs in the empty eval
# workspace (cwd) before the agent starts; --scaffold only. Invented names.
set -euo pipefail
TODAY="$(python3 -c 'import datetime; print(datetime.date.today().isoformat())')"
mkdir -p .agents/runtime/handoff .agents/runtime/tasks .agents/journal
cat > AGENTS.md <<'MD'
# Проект demo-handoff — инструкции агентам

- Журнал решений: `.agents/journal/YYYY-MM-DD.md` (§10).
- Task-пакеты: `.agents/runtime/tasks/T-###-slug.md` (§9).
- Живое состояние задачи — HANDOFF `.agents/runtime/handoff/YYYY-MM-DD-<slug>.md` (§13).
MD
cat > .agents/runtime/handoff/2026-01-12-readme.md <<MD
---
status: active
session_id: 4b8e1d7c-demo
task: T-001
updated: $TODAY 09:00
---

# HANDOFF: README — раздел «Использование» с примерами

## Цель
README.md получает раздел «Использование» с двумя примерами; критерий готовности — критерии T-001 зелёные.

## Состояние (сделано и чем доказано)
- Черновик раздела написан — \`grep -c '^## Использование' README.md\` → 1

## Следующий шаг
Прогнать \`bash tests/run.sh\`, зафиксировать вывод в «Результат» T-001, коммит.

## Блокеры и вопросы
- нет

## Ключевые файлы и решения
- README.md — целевой файл
- .agents/runtime/tasks/T-001-readme-usage.md — пакет
- Решение: примеры только для bash, без PowerShell (владелец, 2026-01-12)

## Не делать (отменённые направления)
- push pf-handoff наружу — владелец запретил до независимого QA
- трогать Orca-скиллы — отдельный релиз, не эта задача
MD
cat > .agents/runtime/tasks/T-001-readme-usage.md <<MD
---
id: T-001
title: README — раздел «Использование»
status: in_progress
owner: claude
depends_on: []
spec: —
updated: $TODAY
---

## Контекст
Проект demo-handoff. README без раздела «Использование».

## Задача
Добавить раздел «Использование» с двумя примерами.

## Критерии приёмки
- [ ] \`grep -c '^## Использование' README.md\` → 1 — change
- [ ] \`bash tests/run.sh\` → \`3/3 passed\` — change

## Результат (заполняет исполнитель)
MD
printf '# demo-handoff\n\n## Использование\n\n```bash\nbash run.sh --help\nbash run.sh input.txt\n```\n' > README.md
mkdir -p tests
printf '#!/usr/bin/env bash\necho "3/3 passed"\n' > tests/run.sh
chmod +x tests/run.sh
cat > .agents/journal/$TODAY.md <<MD
## 09:00 · claude · T-001
Что: черновик раздела «Использование». Итог: в работе, HANDOFF активен.
MD
