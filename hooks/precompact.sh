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
# Дочерний CLI council.sh (PF_COUNCIL_RUN=1): одноразовый процесс, снимок
# перед сжатием ему не нужен — молчим, вход сливаем, rc 0 (сжатие разрешено;
# QA 2.0.0, тихий режим).
if [ "${PF_COUNCIL_RUN:-}" = 1 ]; then cat >/dev/null 2>&1; exit 0; fi

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

  # Foreign input (T-166): no `"session_id"` key in the raw payload — not
  # Claude Code's PreCompact (garbage, Grok's camelCase `sessionId`, another
  # platform). Not ours to gate: exit 0 with no output and no log line, the
  # compaction of that platform goes ahead. Recognition is on the RAW text, not
  # on the parsed value, on purpose: a Claude payload on a machine without jq
  # and python3 parses to an empty session_id and must still reach the block
  # below (the stderr text promises exactly that case).
  case "$input" in
    *'"session_id"'*) : ;;
    *) return 0 ;;
  esac

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
  printf '%s %s %s %s OK %s guard announced t2: %s\n' "$ts" "${session_id:-?}" "${trigger:-?}" "${cwd_in:-?}" "$snap" "$(guard_t2_status "$log_dir/${session_id:-?}.json")" >> "$log_dir/compacts.log"
  return 0
}

# guard_t2_status STATE_FILE — "yes (announced=N)" / "no (announced=N)" /
# "unknown": did context-guard.sh announce the t2 threshold (and take its
# snapshot) before this compaction? Measured for the retro (T-111): a
# compaction whose t2 was never announced means the guard's reading and the
# harness's disagreed (e.g. the advisor usage spike). t2 follows the guard
# (T-164, T-166): the second value of CONTEXT_GUARD_THRESHOLDS when it is
# valid, else 60. The parse is the guard's own, copied as statusline.sh does
# (the hooks install separately, there is no shared helper to source); a
# drift here makes this log line lie, not the guard.
guard_t2_status() {
  local state_file="$1" ann t2=60
  [ -f "$state_file" ] && [ -r "$state_file" ] || { printf 'unknown'; return 0; }
  ann=$(grep -oE '"announced":[[:space:]]*[0-9]+' "$state_file" 2>/dev/null | grep -oE '[0-9]+' | head -1)
  [ -z "${ann:-}" ] && ann=0
  if [ -n "${CONTEXT_GUARD_THRESHOLDS:-}" ]; then
    local c1 c2 c3 cx
    read -r c1 c2 c3 cx <<< "$CONTEXT_GUARD_THRESHOLDS"
    if [ -n "${c1:-}" ] && [ -n "${c2:-}" ] && [ -n "${c3:-}" ] && [ -z "${cx:-}" ]; then
      case "$c1$c2$c3" in
        *[!0-9]*) : ;;
        *)
          if [ "${#c1}" -le 2 ] && [ "${#c2}" -le 2 ] && [ "${#c3}" -le 2 ]; then
            c1=$((10#$c1)); c2=$((10#$c2)); c3=$((10#$c3))
            if [ "$c1" -ge 1 ] && [ "$c1" -lt "$c2" ] && [ "$c2" -lt "$c3" ] && [ "$c3" -le 99 ]; then
              t2="$c2"
            fi
          fi ;;
      esac
    fi
  fi
  if [ "$ann" -ge "$t2" ] 2>/dev/null; then printf 'yes (announced=%s)' "$ann"; else printf 'no (announced=%s)' "$ann"; fi
}

# stderr намеренно НЕ глушим: на пути блокировки это единственный канал, по
# которому причина доходит до человека и агента.
run
rc=$?
[ "$rc" -eq 2 ] && exit 2
exit 0
