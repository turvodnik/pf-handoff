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
  local input ts log_dir
  input=$(cat)

  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  log_dir="$PF_EFFECTIVE_HOME/.claude/context-state"
  mkdir -p "$log_dir" 2>/dev/null

  # Совсем пустой вход (нулевой длины) — не событие сжатия: харнесс всегда даёт
  # JSON, а обёртка регистрации при недоступном скрипте вход просто сливает, не
  # вызывая хук. Блокировать здесь нельзя — это ровно тот клин, который на
  # Debian устраивала регистрация через /bin/sh: среда, где вход не доехал,
  # запирала бы КАЖДОЕ сжатие. Но и молчать нельзя: раньше эта ветка уходила в
  # rc=0, не оставляя ни снимка, ни строки в журнале, и постфактум было не
  # узнать, что страховка не сработала. Поэтому — след в журнале и rc=0.
  if [ -z "$input" ]; then
    printf '%s ? ? ? SKIPPED-empty-stdin (no payload — compaction allowed, no snapshot)\n' "$ts" >> "$log_dir/compacts.log"
    return 0
  fi

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
    # Единственный текст, который обязан прочитать застрявший человек, — и он
    # в EN-дистрибутиве обязан быть английским (конвенция T-032: что видит
    # чужой пользователь — EN, короткая русская строка рядом). Внутренний
    # номер правила (I-036) убран: снаружи он нигде не расшифрован, поэтому
    # правило сказано словами.
    cat >&2 <<EOF
[COMPACTION STOPPED] pf-handoff could not write the automatic session snapshot
(the project directory and the emergency directory are both unwritable, or
autocheckpoint.sh is missing next to precompact.sh, or neither jq nor python3
is installed, so the session id could not be read).

Compacting now would drop the session state with nothing saved — worse than not
compacting at all. What you (or the agent) can do:
  1. run the pf-handoff skill by hand (a full state checkpoint);
  2. fix write access (<project>/.agents/runtime/handoff and
     ~/.claude/context-state/handoff);
  3. install jq or python3 if neither is present;
  4. then compact again.

(RU) Сжатие остановлено: авто-снимок состояния записать не удалось — сделай
pf-handoff руками или почини запись, потом повтори сжатие.
EOF
    return 2
  fi

  # Пустой $snap при rc=0 бывает ровно в одном случае: сессия субагента, где
  # снимок сознательно не пишется (autocheckpoint.sh). Раньше строка выглядела
  # как «OK ?» — читалось как «снимок сделан», хотя файла нет.
  if [ -z "$snap" ]; then
    printf '%s %s %s %s SKIPPED-subagent (no snapshot by design)\n' "$ts" "${session_id:-?}" "${trigger:-?}" "${cwd_in:-?}" >> "$log_dir/compacts.log"
    return 0
  fi
  printf '%s %s %s %s OK %s\n' "$ts" "${session_id:-?}" "${trigger:-?}" "${cwd_in:-?}" "$snap" >> "$log_dir/compacts.log"
  return 0
}

# stderr намеренно НЕ глушим: на пути блокировки это единственный канал, по
# которому причина доходит до человека и агента.
run
rc=$?
[ "$rc" -eq 2 ] && exit 2
exit 0
