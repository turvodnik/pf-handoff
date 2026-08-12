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

# tests/threshold-parity.sh (T-014/F-20): the one canon test file, kept next
# to the hooks in _tools but NOT under hooks/ in this distribution — tests/
# sits beside hooks/ here (T-016), so the rsync filter above deliberately
# does not descend into context-hooks/tests/ (no --include='*/', on purpose:
# doing so would land the file at hooks/tests/, not tests/). Transplanted by
# hand instead, with the one line that layout difference forces (HOOKS_DIR).
# Nothing else in tests/ (run.sh etc., also T-016) is canon — untouched here.
TP_SRC="$TOOLS/context-hooks/tests/threshold-parity.sh"
TP_DST="$HERE/tests/threshold-parity.sh"
[ -f "$TP_SRC" ] || { echo "ОШИБКА: не найден $TP_SRC" >&2; exit 2; }
OLD_HOOKS_LINE='HOOKS_DIR="$(cd "$TESTS_DIR/.." && pwd)"'
NEW_HOOKS_LINE='HOOKS_DIR="$(cd "$TESTS_DIR/../hooks" && pwd)"'
# Fail closed on the source: if canon no longer has exactly this line, the
# adaptation below is stale — stop instead of silently shipping wrong logic.
[ "$(grep -cxF "$OLD_HOOKS_LINE" "$TP_SRC")" = 1 ] || {
  echo "ОШИБКА: канон изменил строку HOOKS_DIR в context-hooks/tests/threshold-parity.sh — обнови адаптацию в sync-from-tools.sh руками, не синкай вслепую." >&2
  exit 3
}
mkdir -p "$HERE/tests"
{
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "$OLD_HOOKS_LINE" ]; then printf '%s\n' "$NEW_HOOKS_LINE"; else printf '%s\n' "$line"; fi
  done < "$TP_SRC"
} > "$TP_DST"
chmod +x "$TP_DST"
# Fail closed on the result too: must differ from canon by exactly that one
# line — anything else means canon changed shape and the adaptation needs a
# human, not a silently-wrong sync (this is the exact bug class T-016 found:
# a distribution quietly falling behind canon).
tp_diff_markers="$(diff "$TP_SRC" "$TP_DST" | grep -c '^[<>]' || true)"
if [ "$tp_diff_markers" != 2 ] || ! grep -qxF "$NEW_HOOKS_LINE" "$TP_DST"; then
  echo "ОШИБКА: tests/threshold-parity.sh разошёлся с каноном сверх одной строки HOOKS_DIR — проверь sync-from-tools.sh руками." >&2
  diff "$TP_SRC" "$TP_DST" >&2 || true
  exit 3
fi

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
