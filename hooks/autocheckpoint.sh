#!/bin/bash
# autocheckpoint.sh — механический снимок состояния сессии (страховочная сетка).
#
# ЧТО ЭТО ТАКОЕ И ЧЕМ НЕ ЯВЛЯЕТСЯ (T-031). Хук не может ни сжать контекст, ни
# заставить агента что-либо сделать: единственные каналы хука — stdout, stderr и
# код возврата (docs code.claude.com/docs/en/hooks-guide.md). Значит «чекпоинт
# сам» может означать только одно честное: снимок пишет САМ СКРИПТ, из фактов,
# которые видно с диска (git, task-пакеты, хвост транскрипта). Это НЕ pf-handoff:
# скрипт не умеет отличать доказанное от заявленного. Смысловой чекпоинт
# по-прежнему делает агент — снимок лишь гарантирует, что сжатие никогда не
# происходит на пустом месте.
#
# Контракт вызова:
#   autocheckpoint.sh --session <id> --cwd <dir> [--transcript <path>] [--reason <текст>]
#   stdout — путь записанного файла (одна строка), rc=0;
#   rc=1   — снимок записать НЕ удалось, причина в stderr (вызывающий обязан
#            считать это шумным состоянием: precompact.sh на этом блокирует
#            сжатие, context-guard.sh — кричит вместо «всё сохранено»).
# Никогда не висим: все внешние команды ограничены хвостом/числом строк.
set -u

PF_EFFECTIVE_HOME="${HOME:-${TMPDIR:-/tmp}}"

SESSION="" CWD_IN="" TRANSCRIPT="" REASON="unspecified"
while [ $# -gt 0 ]; do
  case "$1" in
    --session)    SESSION="${2:-}"; shift 2 ;;
    --cwd)        CWD_IN="${2:-}"; shift 2 ;;
    --transcript) TRANSCRIPT="${2:-}"; shift 2 ;;
    --reason)     REASON="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

[ -n "$SESSION" ] || { echo "autocheckpoint: пустой session_id" >&2; exit 1; }
# session_id становится именем файла — только безопасные символы.
case "$SESSION" in *[!A-Za-z0-9._-]*) echo "autocheckpoint: недопустимый session_id" >&2; exit 1 ;; esac
# Субагенты (agent-*) снимок не пишут: у субагента своё короткое окно и своя
# задача, его handoff-файл — шум в каталоге проекта. Не ошибка, а осознанный
# пропуск, поэтому rc=0 (вызывающему нечего блокировать).
case "$SESSION" in agent-*) echo "autocheckpoint: субагент — снимок не нужен" >&2; exit 0 ;; esac

TODAY=$(date +%Y-%m-%d)
NOW=$(date '+%Y-%m-%d %H:%M:%S')

# --- сбор фактов -----------------------------------------------------------
git_block() {
  [ -n "$CWD_IN" ] && [ -d "$CWD_IN" ] || { echo "(каталог проекта неизвестен)"; return 0; }
  git -C "$CWD_IN" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "(не git-репозиторий)"; return 0; }
  echo "- ветка: $(git -C "$CWD_IN" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null)"
  echo "- незакоммиченное (первые 40 строк \`git status --short\`):"
  git -C "$CWD_IN" --no-optional-locks status --short 2>/dev/null | head -40 | sed 's/^/    /'
  echo "- последние коммиты:"
  git -C "$CWD_IN" --no-optional-locks log --oneline -5 2>/dev/null | sed 's/^/    /'
}

tasks_block() {
  local dir="$CWD_IN/.agents/runtime/tasks" f st id
  [ -d "$dir" ] || { echo "(task-пакетов нет)"; return 0; }
  local found=0
  for f in "$dir"/T-*.md; do
    [ -f "$f" ] || continue
    st=$(grep -m1 '^status:' "$f" 2>/dev/null | sed 's/^status:[[:space:]]*//')
    case "$st" in done|cancelled|"") continue ;; esac
    id=$(basename "$f")
    echo "- $id — $st"
    found=1
  done
  [ "$found" = 0 ] && echo "(открытых пакетов нет)"
  return 0
}

handoff_block() {
  local dir="$CWD_IN/.agents/runtime/handoff"
  [ -d "$dir" ] || { echo "(каталога handoff нет)"; return 0; }
  ls -t "$dir" 2>/dev/null | head -5 | sed 's/^/- /'
}

# Хвост транскрипта: последние реплики человека — самое дорогое, что теряется
# при сжатии. Ограничены 400 КБ хвоста и 5 репликами, чтобы уложиться в бюджет
# хука (таймаут 10 с в settings.json).
prompts_block() {
  [ -n "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ] || { echo "(транскрипт недоступен)"; return 0; }
  command -v python3 >/dev/null 2>&1 || { echo "(python3 недоступен — реплики не извлечены)"; return 0; }
  tail -c 400000 -- "$TRANSCRIPT" 2>/dev/null | python3 -c '
import json, sys
out = []
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    if d.get("type") != "user":
        continue
    m = d.get("message") or {}
    c = m.get("content")
    txt = ""
    if isinstance(c, str):
        txt = c
    elif isinstance(c, list):
        txt = " ".join(p.get("text", "") for p in c if isinstance(p, dict) and p.get("type") == "text")
    txt = " ".join(txt.split())
    if txt and not txt.startswith("<"):
        out.append(txt[:300])
for t in out[-5:]:
    print("- " + t)
if not out:
    print("(реплик не найдено)")
' 2>/dev/null || echo "(разбор транскрипта не удался)"
}

window_block() {
  local sf="$PF_EFFECTIVE_HOME/.claude/context-state/$SESSION.json"
  [ -r "$sf" ] || { echo "(состояние окна неизвестно)"; return 0; }
  local pct win
  pct=$(grep -oE '"pct":[[:space:]]*[0-9]+' "$sf" 2>/dev/null | grep -oE '[0-9]+' | head -1)
  win=$(grep -oE '"window":[[:space:]]*[0-9]+' "$sf" 2>/dev/null | grep -oE '[0-9]+' | head -1)
  echo "- заполнение окна на момент снимка: ${pct:-?}% от ${win:-?} токенов"
}

# --- запись ----------------------------------------------------------------
# I-037: перед КАЖДОЙ записью проверяем, что цель не симлинк (дважды за сутки
# запись уходила по симлинку в чужой файл).
write_to() {
  local base="$1" target tmp
  mkdir -p "$base" 2>/dev/null || return 1
  [ -d "$base" ] && [ -w "$base" ] || return 1
  target="$base/$TODAY-auto-$SESSION.md"
  [ -L "$target" ] && { echo "autocheckpoint: цель — симлинк, запись отменена: $target" >&2; return 1; }
  tmp="$base/.tmp.autockpt.$$.$RANDOM"
  [ -L "$tmp" ] && return 1
  {
    echo "# Авто-снимок состояния сессии (страховочная сетка, T-031)"
    echo
    echo "Это НЕ pf-handoff: файл собран скриптом из фактов на диске, смысловую"
    echo "сверку («что доказано, а что заявлено») делает агент. Снимок нужен,"
    echo "чтобы сжатие контекста не происходило на пустом месте."
    echo
    echo "- время: $NOW"
    echo "- причина: $REASON"
    echo "- сессия: $SESSION"
    echo "- каталог: ${CWD_IN:-?}"
    echo "- транскрипт: ${TRANSCRIPT:-?}"
    window_block
    echo
    echo "## Git"
    git_block
    echo
    echo "## Открытые task-пакеты"
    tasks_block
    echo
    echo "## Живые HANDOFF-файлы проекта"
    handoff_block
    echo
    echo "## Последние реплики человека (до 5)"
    prompts_block
  } > "$tmp" 2>/dev/null
  if [ -s "$tmp" ]; then
    [ -L "$target" ] && { rm -f "$tmp" 2>/dev/null; return 1; }
    mv -f "$tmp" "$target" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    printf '%s\n' "$target"
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

# Основное место — каталог проекта; аварийное — под $HOME (ниже вероятность
# отказа, чем у произвольного рабочего каталога). Блокировка сжатия наступает
# только если не удалось НИ ТУДА, НИ СЮДА.
if [ -n "$CWD_IN" ] && [ -d "$CWD_IN/.agents" ]; then
  write_to "$CWD_IN/.agents/runtime/handoff" && exit 0
fi
write_to "$PF_EFFECTIVE_HOME/.claude/context-state/handoff" && exit 0

echo "autocheckpoint: снимок не записан ни в проект, ни в аварийный каталог" >&2
exit 1
