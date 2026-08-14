#!/bin/bash
# PreCompact — ворота перед сжатием контекста (T-031).
#
# До T-031 хук только дописывал строку в лог. Теперь он делает две вещи:
#  1) вызывает autocheckpoint.sh — снимок состояния пишется САМ, без участия
#     агента, перед КАЖДЫМ сжатием: и автоматическим (порог autoCompactWindow),
#     и ручным `/compact` (ровно тот случай, из-за которого ручной сброс
#     контекста ощущался как риск);
#  2) если снимок не удался — возвращает exit 2, и сжатие НЕ выполняется.
#     Это документированное поведение, а не догадка: таблица «Exit code 2
#     behavior per event» (code.claude.com/docs/en/hooks.md) для PreCompact —
#     «Can block? Yes … Blocks compaction». Правило I-036: сжать контекст,
#     потеряв состояние, хуже, чем не сжать.
#
# Контракт «никогда не мешать сессии» сохраняется для НЕОЖИДАННЫХ ошибок:
# любая поломка самого скрипта даёт rc=0 (сжатие идёт), блокировка возможна
# ТОЛЬКО из явной ветки «снимок не записан». Инициировать сжатие хук не может
# ни при каких настройках — таких полей вывода у хуков нет.
set -u

HOOK_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
PF_EFFECTIVE_HOME="${HOME:-${TMPDIR:-/tmp}}"

# rc=0 — сжатие разрешено, rc=2 — заблокировано.
run() {
  local input
  input=$(cat)
  [ -z "$input" ] && return 0

  local has_jq=0
  command -v jq >/dev/null 2>&1 && has_jq=1

  local row session_id trigger cwd_in transcript_path
  if [ "$has_jq" = 1 ]; then
    row=$(printf '%s' "$input" | jq -r '[(.session_id // ""), (.trigger // ""), (if (.workspace|type) == "object" and ((.workspace.current_dir // "") != "") then .workspace.current_dir else (.cwd // "") end), (.transcript_path // "")] | join("\u001f")' 2>/dev/null)
  else
    row=$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
ws = d.get("workspace")
cwd = (ws.get("current_dir") if isinstance(ws, dict) else None) or d.get("cwd") or ""
print("\x1f".join([str(d.get("session_id") or ""), str(d.get("trigger") or ""), cwd, str(d.get("transcript_path") or "")]))
' 2>/dev/null)
  fi
  IFS=$'\x1f' read -r session_id trigger cwd_in transcript_path <<< "$row"

  local ts log_dir
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  log_dir="$PF_EFFECTIVE_HOME/.claude/context-state"
  mkdir -p "$log_dir" 2>/dev/null

  # --- обязательный снимок перед сжатием -----------------------------------
  local ac="$HOOK_DIR/autocheckpoint.sh" snap="" rc=0
  if [ -f "$ac" ] && [ -r "$ac" ]; then
    snap=$(bash "$ac" --session "${session_id:-}" --cwd "${cwd_in:-}" \
             --transcript "${transcript_path:-}" \
             --reason "PreCompact (trigger=${trigger:-?})" 2>/dev/null)
    rc=$?
  else
    rc=1
    snap=""
  fi

  if [ "$rc" -ne 0 ]; then
    printf '%s %s %s %s BLOCKED-no-checkpoint\n' "$ts" "${session_id:-?}" "${trigger:-?}" "${cwd_in:-?}" >> "$log_dir/compacts.log"
    cat >&2 <<EOF
[СЖАТИЕ ОСТАНОВЛЕНО] Авто-снимок состояния сессии записать НЕ удалось
(каталог проекта и аварийный каталог недоступны для записи, либо отсутствует
autocheckpoint.sh рядом с precompact.sh).

Сжимать контекст сейчас нельзя: правило I-036 — потерять состояние хуже, чем
не сжать. Что делать человеку или агенту:
  1. выполнить pf-handoff руками (полный чекпоинт состояния);
  2. починить запись (права на <проект>/.agents/runtime/handoff и на
     ~/.claude/context-state/handoff);
  3. повторить сжатие.
EOF
    return 2
  fi

  printf '%s %s %s %s OK %s\n' "$ts" "${session_id:-?}" "${trigger:-?}" "${cwd_in:-?}" "${snap:-?}" >> "$log_dir/compacts.log"
  return 0
}

# stderr намеренно НЕ глушим: на пути блокировки это единственный канал, по
# которому причина доходит до человека и агента.
run
rc=$?
[ "$rc" -eq 2 ] && exit 2
exit 0
