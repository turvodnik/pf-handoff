#!/usr/bin/env bash
# Fixture for resume-stops-on-stale-handoff: an ACTIVE HANDOFF dated 10 days
# ago (`updated:` computed — the case must stay stale on any day it runs; the
# file NAME is fixed, 2026-01-02-parser.md, because graders read it by path —
# staleness is decided by `updated:`, not by the name) that says the
# packet is half done, while the packet itself is already in `status: review`
# with a filled «Результат». Deliberately NOT `done`/`cancelled`: for those
# pf-resume step 3 tells the agent to close the file itself (an Edit), and the
# graders here forbid every edit — the stop must be the only correct move.
# Runs in the empty eval workspace (cwd) before the agent starts; --scaffold
# only. Invented names.
set -euo pipefail
OLD="$(python3 -c 'import datetime; print((datetime.date.today()-datetime.timedelta(days=10)).isoformat())')"
TODAY="$(python3 -c 'import datetime; print(datetime.date.today().isoformat())')"
mkdir -p .agents/runtime/handoff .agents/runtime/tasks .agents/journal
cat > AGENTS.md <<'MD'
# Проект demo-stale — инструкции агентам

- Журнал решений: `.agents/journal/YYYY-MM-DD.md` (§10).
- Task-пакеты: `.agents/runtime/tasks/T-###-slug.md` (§9).
- Живое состояние задачи — HANDOFF `.agents/runtime/handoff/YYYY-MM-DD-<slug>.md` (§13).
MD
cat > .agents/runtime/handoff/2026-01-02-parser.md <<MD
---
status: active
session_id: 7e5f3a9b-demo
task: T-001
updated: $OLD 18:40
---

# HANDOFF: парсер конфигурации — половина сделана

## Цель
\`parse.sh\` читает config.ini и печатает ключи; критерий готовности — критерии T-001 зелёные.

## Состояние (сделано и чем доказано)
- Чтение секций реализовано — \`bash parse.sh config.ini | head -1\` → \`[main]\`

## Следующий шаг
Реализовать чтение ключей внутри секций (вторая половина T-001), затем тесты.

## Блокеры и вопросы
- нет

## Ключевые файлы и решения
- parse.sh — целевой скрипт
- .agents/runtime/tasks/T-001-config-parser.md — пакет

## Не делать (отменённые направления)
- переписывать на python — владелец: только bash
MD
cat > .agents/runtime/tasks/T-001-config-parser.md <<MD
---
id: T-001
title: parse.sh — чтение секций и ключей config.ini
status: review
owner: codex
depends_on: []
spec: —
updated: $TODAY
---

## Контекст
Проект demo-stale. Нужен bash-парсер config.ini.

## Задача
Секции и ключи; тесты.

## Критерии приёмки
- [ ] \`bash parse.sh config.ini\` печатает секции и ключи — change
- [ ] \`bash tests/run.sh\` → \`4/4 passed\` — change

## Результат (заполняет исполнитель)
Сделано полностью (секции и ключи), тесты 4/4 — вывод: \`4/4 passed\`. Коммит 5e6f7a8. Статус review — ждёт ревьюера.
MD
printf '#!/usr/bin/env bash\ngrep -E "^\\[|=" "${1:?config}"\n' > parse.sh
printf '[main]\nname=demo\n' > config.ini
mkdir -p tests
printf '#!/usr/bin/env bash\necho "4/4 passed"\n' > tests/run.sh
chmod +x parse.sh tests/run.sh
cat > ".agents/journal/$OLD.md" <<MD
## 18:40 · claude · T-001
Что: секции читаются. Итог: половина, HANDOFF активен.
MD
cat > ".agents/journal/$TODAY.md" <<MD
## 11:00 · codex · T-001
Что: ключи + тесты 4/4. Итог: T-001 → review.
MD
