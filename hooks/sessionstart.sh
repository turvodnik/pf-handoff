#!/bin/bash
# Автоподхват HANDOFF на старте/резюме/после компакта сессии Claude Code.
# Контракт: НИКОГДА не падать и не блокировать сессию (see statusline.sh header).
set -u
# Дочерний CLI council.sh (PF_COUNCIL_RUN=1): одноразовый процесс, HANDOFF и
# реестр ему не нужны — молчим, вход сливаем, rc 0 (QA 2.0.0, тихий режим).
if [ "${PF_COUNCIL_RUN:-}" = 1 ]; then cat >/dev/null 2>&1; exit 0; fi

# Тот же контракт, что в statusline.sh/context-guard.sh/doctor.sh (F-20): под
# `set -u` голый $HOME в среде без HOME — это «unbound variable», то есть смерть
# скрипта. Наружу это выглядело как rc=0 и пустой вывод — «живых шпаргалок
# нет», хотя они есть: подхват HANDOFF молча терялся. Этот хук был последним
# без PF_EFFECTIVE_HOME.
PF_EFFECTIVE_HOME="${HOME:-${TMPDIR:-/tmp}}"

# Единственная точка вывода additionalContext (переиспользуется всеми путями
# выхода run(), включая «cwd не проект» до появления HANDOFF-контекста).
# Локальные переменные вызывающей run() (has_jq, project_dir, sid) видны здесь по
# динамической области видимости bash — emit_ctx вызывается только из run(),
# и всегда после того, как project_dir уже определён.
emit_ctx() {
  local ctx="$1" sid8
  # Строка сессии (QA pf-workflow 2.0.0, Ж-5): агент не видит свой session_id,
  # а HANDOFF и реестр его требуют. Первые 8 знаков, только [A-Za-z0-9_-] —
  # это значение из входа хука, не из файла. Последней строкой.
  sid8=$(printf '%s' "${sid:-}" | tr -cd 'A-Za-z0-9_-' | cut -c1-8)
  if [ -n "$sid8" ]; then
    ctx="${ctx:+$ctx
}Сессия: ${sid8} — это значение поля session_id в HANDOFF/реестре."
  fi
  # Ничего собрать не удалось (ни warn, ни HANDOFF, ни id сессии) -> молчим.
  [ -n "$ctx" ] || return 0
  if [ "$has_jq" = 1 ]; then
    jq -n --arg ctx "$ctx" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
  else
    SS_MSG="$ctx" python3 -c '
import json, os
print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": os.environ["SS_MSG"]}}))
'
  fi
}

# Поле из файла HANDOFF идёт в контекст модели — не целиком: не длиннее
# 120 знаков (QA 2.0.0, Y3). Режем по знакам, а не байтам (кириллица): через
# python3; без него — подстрока bash (в UTF-8-локали тоже по знакам).
clip_field() {
  if command -v python3 >/dev/null 2>&1; then
    SS_V="$1" python3 -c '
import os, sys
v = os.environ["SS_V"]
v = v if len(v) <= 120 else v[:119] + "\u2026"
sys.stdout.buffer.write(v.encode("utf-8", "surrogateescape"))
' 2>/dev/null
  else
    printf '%s' "${1:0:120}"
  fi
}

# Список ожидания (T-165): строки реестра автопилота активного HANDOFF в
# статусе «запущен». Разбор таблицы — копия логики skill-library/hooks/
# wait-guard.sh (RUNNING_WORD/NEGATED/split_row/running_rows: колонка «Статус»
# по заголовку, «НЕ запущен» не работает, `\|` внутри ячейки); дистрибутивы
# ставятся по отдельности, поэтому копия, а не вызов чужого файла. Печатает ОДНУ
# строку «<ячейки до Статуса через · > ; …» либо ничего: нет python3, нет
# таблицы, любая ошибка -> пусто (хук не мешает работе).
running_wait_list() {
  command -v python3 >/dev/null 2>&1 || return 0
  SS_HANDOFF="$1" python3 -c '
import os, re

RUNNING_WORD = re.compile(r"(?<![А-Яа-яЁё])(?:пере)?запущен[аоы]?(?![А-Яа-яЁё])", re.IGNORECASE)
NEGATED = re.compile(r"(?<![А-Яа-яЁё])не[\s*_`~]*$", re.IGNORECASE)
STATUS_HEADER = re.compile(r"^[\s*_`~]*(?:статус|status)[\s*_`~]*$", re.IGNORECASE)

def status_running(cell):
    return any(not NEGATED.search(cell[:m.start()]) for m in RUNNING_WORD.finditer(cell))

def split_row(line):
    return [c.strip() for c in re.split(r"(?<!\\)\|", line.strip().strip("|"))]

def is_separator(cells):
    return bool(cells) and bool(cells[0]) and set(cells[0]) <= set("-: ")

def items(path):
    out = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = [line.strip() for line in fh]
    status_idx, ncols = None, 0
    for i, s in enumerate(lines):
        if not s.startswith("|"):
            continue
        cells = split_row(s)
        if is_separator(cells):
            continue
        nxt = lines[i + 1] if i + 1 < len(lines) else ""
        if nxt.startswith("|") and is_separator(split_row(nxt)):
            hits = [k for k, c in enumerate(cells) if STATUS_HEADER.match(c)]
            status_idx, ncols = (hits[0] if hits else None), len(cells)
            continue
        if status_idx is None or status_idx == ncols - 1:
            status, head = cells[-1], cells[:-1]
        elif len(cells) == ncols:
            status, head = cells[status_idx], cells[:status_idx] + cells[status_idx + 1:]
        else:
            status, head = " | ".join(cells), [c for c in cells if not RUNNING_WORD.search(c)]
        if not status_running(status):
            continue
        label = " · ".join(c for c in head if c) or s[:60]
        out.append(label if len(label) <= 120 else label[:119] + "\u2026")   # QA 2.0.0 Y3
    return out

try:
    print("; ".join(items(os.environ["SS_HANDOFF"])))
except Exception:
    pass
' 2>/dev/null | head -n 1 | tr -d '\r'
  return 0
}

# Чей HANDOFF (T-165, фикс-раунды 1–2): печатает own — `session_id` во
# frontmatter совпал с id сессии из stdin (как в wait-guard.sh: комментарий
# после значения отбрасывается; полное совпадение или префикс файла >= 8
# знаков); none — session_id не задан, пуст или «—» (шаблон pf-handoff по
# умолчанию), такой HANDOFF чужим не считается; foreign — задан и не совпал.
# Нет python3 / ошибка -> none (поведение «как до фикса»).
handoff_owner() {
  command -v python3 >/dev/null 2>&1 || { echo none; return 0; }
  SS_HANDOFF="$1" SS_SID="${2:-}" python3 -c '
import os
res = "none"
try:
    with open(os.environ["SS_HANDOFF"], encoding="utf-8", errors="replace") as fh:
        lines = [l for _, l in zip(range(200), fh)]
    fm = []
    if lines and lines[0].strip() == "---":
        for l in lines[1:]:
            if l.strip() == "---":
                break
            fm.append(l)
    fid = None
    for l in fm:
        t = l.strip()
        if t.startswith("session_id:"):
            fid = t[11:].split("#", 1)[0].strip().strip("`\"\x27")
            break
    sid = os.environ["SS_SID"]
    if fid and fid not in ("—", "-", "–"):
        res = "own" if (fid == sid or (len(fid) >= 8 and sid.startswith(fid))) else "foreign"
except Exception:
    res = "none"
print(res)
' 2>/dev/null | head -n 1
  return 0
}

run() {
  local input
  input=$(cat)
  [ -z "$input" ] && return 0

  local has_jq=0
  command -v jq >/dev/null 2>&1 && has_jq=1

  local row source cwd_in sid
  if [ "$has_jq" = 1 ]; then
    #  вместо таба: табы у bash-read схлопываются, пустые поля сдвигают соседей.
    row=$(printf '%s' "$input" | jq -r '[(.source // ""), (.cwd // ""), (.session_id // "")] | join("\u001f")' 2>/dev/null)
  else
    row=$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print("\x1f".join([str(d.get("source") or ""), str(d.get("cwd") or ""), str(d.get("session_id") or "")]))
' 2>/dev/null)
  fi
  IFS=$'\x1f' read -r source cwd_in sid <<< "$row"

  case "$source" in
    startup|resume|compact|clear) : ;;
    *) return 0 ;;
  esac

  # Лёгкая уборка раз в сессию: state-файлы старше 14 суток никому не нужны.
  find "$PF_EFFECTIVE_HOME/.claude/context-state" -name '*.json' -mtime +14 -delete 2>/dev/null

  local project_dir handoff_dir warn
  project_dir="${CLAUDE_PROJECT_DIR:-$cwd_in}"
  [ -z "$project_dir" ] && return 0

  # Р14/I-077: сессия из чужой/пустой папки работает молча — снимки и заявки
  # уходят в глобальные папки (~/.claude/context-state/handoff/), а не в
  # проект. Признак «не проект» — нет ни AGENTS.md, ни .agents/.
  warn=""
  if [ ! -f "$project_dir/AGENTS.md" ] && [ ! -d "$project_dir/.agents" ]; then
    warn="⚠ cwd не проект: ${project_dir} — снимки и заявки уйдут в глобальные папки"
  fi

  handoff_dir="$project_dir/.agents/runtime/handoff"
  if [ ! -d "$handoff_dir" ]; then
    emit_ctx "$warn"
    return 0
  fi

  local now cutoff
  now=$(date +%s)
  cutoff=$(( now - 7*24*3600 ))

  # Собрать "mtime<TAB>путь" для *.md со status: active во фронтматтере и
  # mtime не старше 7 суток.
  local listing f mtime
  listing=""
  for f in "$handoff_dir"/*.md; do
    [ -f "$f" ] || continue
    # Время правки файла: у BSD/macOS `stat -f %m`, у GNU/Linux `stat -c %Y` —
    # это РАЗНЫЕ программы с одинаковым именем. Раньше стояла только BSD-форма,
    # и на Linux каждый файл молча выпадал из списка: подхват HANDOFF там не
    # работал вообще, а выглядело это как «живых шпаргалок нет» (I-036 —
    # «не смог проверить» обязано отличаться от «проверил, чисто»).
    mtime=$(stat -f %m "$f" 2>/dev/null) || mtime=""
    # Проверяем не код возврата, а РЕЗУЛЬТАТ: GNU-шный stat при `-f` печатает
    # сведения о файловой системе, то есть «успех» с непригодным выводом.
    case "$mtime" in ''|*[!0-9]*) mtime=$(stat -c %Y "$f" 2>/dev/null) || mtime="" ;; esac
    case "$mtime" in ''|*[!0-9]*) continue ;; esac
    if [ "$mtime" -lt "$cutoff" ] 2>/dev/null; then continue; fi
    # Смотрим ТОЛЬКО frontmatter (между первой и второй «---»): строка
    # «status: active» в теле файла не должна оживлять closed-шпаргалку.
    # «active» может сопровождаться хвостом-комментарием — терпим всё после пробела.
    if awk 'NR==1 && $0!="---"{exit 1} NR>1 && $0=="---"{exit} NR>1{print}' "$f" 2>/dev/null \
       | grep -qE '^status:[[:space:]]*"?active"?([[:space:]]|$)'; then
      listing="${listing}${mtime}	${f}
"
    fi
  done
  if [ -z "$listing" ]; then
    emit_ctx "$warn"
    return 0
  fi

  local top context_lines line task_field extra hours wait_list
  top=$(printf '%s' "$listing" | sort -rn | head -n 3)
  # compact/resume/clear: 1) свой HANDOFF по session_id; 2) иначе самый свежий
  # без session_id (или «—») — со списком; 3) иначе самый свежий чужой — без
  # списка (чужие субагенты — не наши). startup — как раньше.
  local pick_f="" pick_mtime="" own_ok=1 sorted_all m2 f2 who none_f="" none_m=""
  if [ "$source" = "compact" ] || [ "$source" = "resume" ] || [ "$source" = "clear" ]; then
    sorted_all=$(printf '%s' "$listing" | sort -rn)
    while IFS=$'\t' read -r m2 f2; do
      [ -z "$f2" ] && continue
      who=$(handoff_owner "$f2" "${sid:-}")
      if [ "$who" = own ]; then pick_f="$f2"; pick_mtime="$m2"; break; fi
      if [ "$who" = none ] && [ -z "$none_f" ]; then none_f="$f2"; none_m="$m2"; fi
    done <<< "$sorted_all"
    if [ -z "$pick_f" ] && [ -n "$none_f" ]; then pick_f="$none_f"; pick_mtime="$none_m"; fi
    if [ -z "$pick_f" ]; then
      own_ok=0
    else
      top="${pick_mtime}	${pick_f}
$(printf '%s\n' "$top" | grep -vF "	${pick_f}")"
      top=$(printf '%s' "$top" | head -n 3)
    fi
  fi
  context_lines=""
  while IFS=$'\t' read -r mtime f; do
    [ -z "$f" ] && continue
    hours=$(( (now - mtime) / 3600 ))
    task_field=$(head -n 20 "$f" 2>/dev/null | grep -E '^task:' | head -1 | sed -E 's/^task:[[:space:]]*//; s/[[:space:]]*$//; s/^"(.*)"$/\1/' | tr -d '\r')
    case "${task_field:-}" in
      ""|"—") extra="" ;;
      *) extra=", задача «$(clip_field "$task_field")»" ;;
    esac
    if [ -z "$context_lines" ]; then
      if [ "$source" = "clear" ]; then
        # T-168: после ручного /clear человек сам решает, продолжать ли, —
        # только указатель, без «продолжи» и без списка ожидания.
        line="Активный HANDOFF ${f} — /pf-resume $(basename "$f" .md) (источник: clear, обновлён ${hours} ч назад${extra})."
        context_lines="$line"
        continue
      fi
      # T-165 (SPEC v3 разд. 3): после сжатия и на резюме HANDOFF свежий (его
      # пишет агент на 75 %), поэтому первая строка — «прочитай и продолжи»;
      # ручной и автоматический compact ведут себя одинаково. На свежем старте
      # (QA 2.0.0, Y3) — только перечень, как обещает README: новый чат может
      # быть о другой задаче, а HANDOFF — чужим (параллельная сессия, файл из
      # чужого репозитория); продолжать ли — решает человек (/pf-resume).
      if [ "$source" = "startup" ]; then
        line="Активный HANDOFF ${f} — /pf-resume $(basename "$f" .md) (источник: startup, обновлён ${hours} ч назад${extra}). Продолжать ли — решает человек."
      else
        line="Прочитай HANDOFF ${f} и продолжи (источник: ${source}, обновлён ${hours} ч назад${extra})."
      fi
      wait_list=""
      [ "$own_ok" = 1 ] && wait_list=$(running_wait_list "$f")
      if [ -n "$wait_list" ]; then
        # T-168 (фикс-раунд 1): на startup субагенты закрытой сессии не
        # вернутся, но детач-процессы (council.sh --async через nohup, PID)
        # могут быть живы, а реестр может принадлежать параллельной живой
        # сессии — поэтому не «ждать» и не «не ждать», а «сверить».
        if [ "$source" = "startup" ]; then
          line="${line} Запущены по реестру прошлой сессии: ${wait_list}. Субагенты закрытой сессии не вернутся — сверь статусы пакетов; маркер или PID council проверь через \`council.sh --wait\` / \`kill -0\`; чужие задания не перезапускай."
          [ "$(handoff_owner "$f" "${sid:-}")" = foreign ] && line="${line} (HANDOFF другой сессии — она может быть жива)"
        else
          line="${line} Ты ждёшь: ${wait_list}."
        fi
      fi
      context_lines="$line"
    else
      context_lines="$context_lines
Ещё активный HANDOFF: ${f} (обновлён ${hours} ч назад${extra})."
    fi
  done <<< "$top"

  if [ -z "$context_lines" ]; then
    emit_ctx "$warn"
    return 0
  fi

  # Строка «cwd не проект» — после первой строки «Прочитай HANDOFF».
  if [ -n "$warn" ]; then
    context_lines="$context_lines
$warn"
  fi

  emit_ctx "$context_lines"
  return 0
}

( run ) 2>/dev/null
exit 0
