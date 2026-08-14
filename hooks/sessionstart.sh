#!/bin/bash
# Автоподхват HANDOFF на старте/резюме/после компакта сессии Claude Code.
# Контракт: НИКОГДА не падать и не блокировать сессию (see statusline.sh header).
set -u

# Тот же контракт, что в statusline.sh/context-guard.sh/doctor.sh (F-20): под
# `set -u` голый $HOME в среде без HOME — это «unbound variable», то есть смерть
# скрипта. Наружу это выглядело как rc=0 и пустой вывод — «живых шпаргалок
# нет», хотя они есть: подхват HANDOFF молча терялся. Этот хук был последним
# без PF_EFFECTIVE_HOME.
PF_EFFECTIVE_HOME="${HOME:-${TMPDIR:-/tmp}}"

run() {
  local input
  input=$(cat)
  [ -z "$input" ] && return 0

  local has_jq=0
  command -v jq >/dev/null 2>&1 && has_jq=1

  local row source cwd_in
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
    startup|resume|compact) : ;;
    *) return 0 ;;
  esac

  # Лёгкая уборка раз в сессию: state-файлы старше 14 суток никому не нужны.
  find "$PF_EFFECTIVE_HOME/.claude/context-state" -name '*.json' -mtime +14 -delete 2>/dev/null

  # Ручной /compact отличаем от автокомпакта по свежей записи precompact.sh:
  # manual — человек действовал осознанно, ему хватит подсказки без автозагрузки;
  # auto — работа шла полным ходом, состояние надо подхватить немедленно.
  local trigger=""
  if [ "$source" = "compact" ] && [ -n "${sid:-}" ] && [ -f "$PF_EFFECTIVE_HOME/.claude/context-state/compacts.log" ]; then
    trigger=$(tail -n 50 "$PF_EFFECTIVE_HOME/.claude/context-state/compacts.log" 2>/dev/null | awk -v s="$sid" '$2==s {t=$3} END {print t}')
  fi

  local project_dir handoff_dir
  project_dir="${CLAUDE_PROJECT_DIR:-$cwd_in}"
  [ -z "$project_dir" ] && return 0
  handoff_dir="$project_dir/.agents/runtime/handoff"
  [ -d "$handoff_dir" ] || return 0

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
  [ -z "$listing" ] && return 0

  local top context_lines line task_field extra hours
  top=$(printf '%s' "$listing" | sort -rn | head -n 3)
  context_lines=""
  while IFS=$'\t' read -r mtime f; do
    [ -z "$f" ] && continue
    hours=$(( (now - mtime) / 3600 ))
    task_field=$(head -n 20 "$f" 2>/dev/null | grep -E '^task:' | head -1 | sed -E 's/^task:[[:space:]]*//; s/[[:space:]]*$//; s/^"(.*)"$/\1/')
    case "${task_field:-}" in
      ""|"—") extra="" ;;
      *) extra=", задача $task_field" ;;
    esac
    line="Продолжение сессии (источник: ${source}). Живое состояние задачи: ${f} (обновлён ${hours} ч назад${extra}). Прочитай его перед продолжением (§13)."
    if [ -z "$context_lines" ]; then
      context_lines="$line"
    else
      context_lines="$context_lines
$line"
    fi
  done <<< "$top"

  [ -z "$context_lines" ] && return 0

  # После компакта поведение зависит от того, кто его сделал.
  # Автокомпакт: свежайшие изменения живут только в сводке компактора —
  # немедленно подхватить HANDOFF и перенести их туда. Ручной /compact:
  # человек действовал сам — только подсказка, ничего не грузим по умолчанию.
  if [ "$source" = "compact" ]; then
    if [ "$trigger" = "manual" ]; then
      local newest_f slug
      newest_f=$(printf '%s' "$top" | head -n 1 | cut -f2)
      slug=$(basename "$newest_f" .md)
      context_lines="Компакт выполнен вручную; прежнее состояние НЕ подгружено. Продолжить прежнюю задачу — /pf-resume ${slug} (файл: ${newest_f}). Новая задача — просто работай, старый HANDOFF не тяни."
    else
      context_lines="$context_lines
Первым делом перенеси свежие изменения из сводки компакта в HANDOFF (pf-handoff), затем продолжай работу."
    fi
  fi

  if [ "$has_jq" = 1 ]; then
    jq -n --arg ctx "$context_lines" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
  else
    SS_MSG="$context_lines" python3 -c '
import json, os
print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": os.environ["SS_MSG"]}}))
'
  fi
  return 0
}

( run ) 2>/dev/null
exit 0
