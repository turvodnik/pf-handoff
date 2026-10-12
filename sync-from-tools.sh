#!/bin/bash
# Синхронизация дистрибутива из канона разработки перед релизом.
# Канон живёт в _tools: skill-library/skills/{pf-handoff,pf-resume} и context-hooks/*.sh.
# Запуск: bash sync-from-tools.sh [путь-к-_tools]
# Дальше руками: git diff → запись в CHANGELOG.md → commit → tag vX.Y.Z → push --tags.
set -euo pipefail

TOOLS="${1:-$HOME/Проекты ai/_tools}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

[ -d "$TOOLS/skill-library/skills/pf-handoff" ] || { echo "ОШИБКА: не найден канон в $TOOLS" >&2; exit 2; }
# evals/ (T-145, SPEC-plugin-evals p. 3): the plugin's eval suite for
# `claude plugin eval` — canon skill-library/evals/pf-handoff/ lands here as
# evals/ (cases + README). Fail closed on the source before the first write.
EVALS_SRC="$TOOLS/skill-library/evals/pf-handoff"
[ -f "$EVALS_SRC/README.md" ] || { echo "ОШИБКА: не найден $EVALS_SRC/README.md" >&2; exit 2; }
# Стоп-лист приватных слов (T-190, QA 2.0.0 Y8): имена клиентских проектов не
# уезжают в публичный дистрибутив. Сам список живёт только в каноне
# (_tools/security/private-words.txt, переопределение — PF_PRIVATE_WORDS) и
# сюда не копируется. Нет списка — синк не начинается: «не смог проверить» не
# равно «чисто».
PW_SRC="${PF_PRIVATE_WORDS:-$TOOLS/security/private-words.txt}"
PW_TMP="$(mktemp "${TMPDIR:-/tmp}/pfh-words.XXXXXX")"
trap 'rm -f "$PW_TMP"' EXIT
{ grep -v '^[[:space:]]*#' "$PW_SRC" 2>/dev/null || true; } | sed 's/[[:space:]]*$//' | { grep -v '^$' || true; } > "$PW_TMP"
[ -s "$PW_TMP" ] || { echo "ОШИБКА: стоп-лист приватных слов не найден или пуст: $PW_SRC (PF_PRIVATE_WORDS)" >&2; exit 2; }

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

# tests/guard-cases.sh + tests/fixtures/ (T-111, 2026-09-16): the second canon
# test file, same HOOKS_DIR adaptation as threshold-parity.sh above; fixtures
# are copied verbatim (they hold only usage/percent fields, no project text).
GC_SRC="$TOOLS/context-hooks/tests/guard-cases.sh"
GC_DST="$HERE/tests/guard-cases.sh"
[ -f "$GC_SRC" ] || { echo "ОШИБКА: не найден $GC_SRC" >&2; exit 2; }
[ "$(grep -cxF "$OLD_HOOKS_LINE" "$GC_SRC")" = 1 ] || {
  echo "ОШИБКА: канон изменил строку HOOKS_DIR в context-hooks/tests/guard-cases.sh — обнови адаптацию в sync-from-tools.sh руками." >&2
  exit 3
}
{
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "$OLD_HOOKS_LINE" ]; then printf '%s\n' "$NEW_HOOKS_LINE"; else printf '%s\n' "$line"; fi
  done < "$GC_SRC"
} > "$GC_DST"
mkdir -p "$HERE/tests/fixtures"
# --exclude pf-resume/: that subfolder is carried from skill-library/tests/
# fixtures/ below, not from context-hooks — without the exclude this --delete
# would sweep it on every sync (fix pass 2026-09-20).
rsync -a --delete --exclude='pf-resume/' "$TOOLS/context-hooks/tests/fixtures/" "$HERE/tests/fixtures/"
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

# evals/ — rsync with --delete so a case removed from canon disappears here
# too; results/ (claude plugin eval output, gitignored) is excluded, so it is
# neither copied nor swept.
mkdir -p "$HERE/evals"
rsync -a --delete --exclude='results/' "$EVALS_SRC/" "$HERE/evals/"

# tests/claims-check-probes.sh (T-030) — батарея скрипта заявок. Приём тот же,
# что у threshold-parity.sh выше: канон лежит в skill-library/tests/ (самотесты
# мастерской), а здесь tests/ соседствует со skills/. Адаптация пути НЕ нужна —
# батарея ищет скрипт по `$TESTS_DIR/../skills/pf-handoff/scripts/…`, и в этом
# дистрибутиве такой путь верен сам по себе. Без этой пересадки наружу уезжал бы
# claims-check.sh без единого своего теста (находка гейта §6, 14.08).
CP_SRC="$TOOLS/skill-library/tests/claims-check-probes.sh"
[ -f "$CP_SRC" ] || { echo "ОШИБКА: не найден $CP_SRC" >&2; exit 2; }
mkdir -p "$HERE/tests"
cp "$CP_SRC" "$HERE/tests/claims-check-probes.sh"
chmod +x "$HERE/tests/claims-check-probes.sh"

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

# Стоп-лист: дерево дистрибутива (отслеживаемые и новые неигнорируемые файлы)
# не должно содержать ни одного слова из списка — ни в тексте, ни в имени файла.
# Только существующие файлы: удалённый, но ещё не закоммиченный файл индекса в дерево не входит.
# Вне git (drift-check гоняет синк на копии без .git) — тот же перечень через
# find, без вывода в stderr. Пропускаются .git, .claude (вложенные worktree
# дистрибутива — чужие ветки, их слова не наши), .agents и evals/results
# (игнорируемый вывод). Git — только если HERE и есть корень репозитория:
# копия внутри чужого репо не должна читать его индекс.
pw_files() {
  local top
  top="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$top" ] && [ "$(cd "$top" && pwd -P)" = "$(cd "$HERE" && pwd -P)" ]; then
    git -C "$HERE" ls-files -z -co --exclude-standard 2>/dev/null | tr '\0' '\n' | while IFS= read -r f; do [ -f "$HERE/$f" ] && printf '%s\n' "$f"; done
  else
    (cd "$HERE" && find . \( -name .git -o -name .claude -o -name .agents -o -path ./evals/results \) -prune -o -type f -print 2>/dev/null | sed 's#^\./##')
  fi
}
pw_hits="$( { pw_files | { grep -iF -f "$PW_TMP" || true; } | sed 's/^/имя файла: /'
              (cd "$HERE" && pw_files | tr '\n' '\0' | xargs -0 grep -IilF -f "$PW_TMP" 2>/dev/null || true) | sed 's/^/текст: /'; } )"
if [ -n "$pw_hits" ]; then
  echo "ОШИБКА: в дереве дистрибутива найдены приватные слова из $PW_SRC — убери их до коммита:" >&2
  printf '%s\n' "$pw_hits" >&2
  exit 4
fi

echo "Синхронизировано из: $TOOLS"
echo "Сгенерирован docs/context-rules.md (EN); русскую версию (docs/context-rules.ru.md) проверь глазами."
echo "Дальше: git diff → CHANGELOG.md → commit → tag vX.Y.Z → git push --tags"
