#!/bin/bash
# Синхронизация дистрибутива из канона разработки перед релизом.
# Канон живёт в _tools: skill-library/skills/{pf-handoff,pf-resume} и context-hooks/*.sh.
# Запуск: bash sync-from-tools.sh [путь-к-_tools]
# Дальше руками: git diff → запись в CHANGELOG.md → commit → tag vX.Y.Z → push --tags.
set -euo pipefail

TOOLS="${1:-$HOME/Проекты ai/_tools}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

[ -d "$TOOLS/skill-library/skills/pf-handoff" ] || { echo "ОШИБКА: не найден канон в $TOOLS" >&2; exit 2; }

rsync -a --delete "$TOOLS/skill-library/skills/pf-handoff/" "$HERE/skills/pf-handoff/"
rsync -a --delete "$TOOLS/skill-library/skills/pf-resume/"  "$HERE/skills/pf-resume/"
rsync -a --delete --include='*.sh' --exclude='*' "$TOOLS/context-hooks/" "$HERE/hooks/"

# docs/context-rules.md (EN) — читаемая человеком копия reference скилла. Канон скилла
# теперь на английском, поэтому ГЕНЕРИРУЕТСЯ английский док; правкам руками не подлежит:
# три копии одного текста (канон → скилл → docs) иначе гарантированно разъезжаются.
REF="$HERE/skills/pf-handoff/references/context-rules.md"
{
  printf '# Context budget and session continuity — full rules\n\n'
  printf '*[Русская версия](context-rules.ru.md)*\n\n'
  printf '> Generated from `skills/pf-handoff/references/context-rules.md` by `sync-from-tools.sh` — do not edit by hand.\n'
  printf '> This is the same text that ships with the skill and that the agent reads on demand; duplicated here for human reading.\n\n'
  tail -n +2 "$REF"
} > "$HERE/docs/context-rules.md"

# Русская версия — ручной перевод (канон стал EN), автоматически синхронизировать её
# нечем. Ловим хотя бы структурное расхождение по числу разделов.
en_h=$(grep -c '^## ' "$REF" || true)
ru_h=$(grep -c '^## ' "$HERE/docs/context-rules.ru.md" || true)
if [ "$en_h" != "$ru_h" ]; then
  echo "ВНИМАНИЕ: разделов в reference ($en_h) и docs/context-rules.ru.md ($ru_h) не совпадает — обнови русский перевод." >&2
fi

echo "Синхронизировано из: $TOOLS"
echo "Сгенерирован docs/context-rules.md (EN); русскую версию (docs/context-rules.ru.md) проверь глазами."
echo "Дальше: git diff → CHANGELOG.md → commit → tag vX.Y.Z → git push --tags"
