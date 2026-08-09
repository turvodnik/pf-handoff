#!/bin/bash
# Пороговые вбросы контекста — одно тело на два события: UserPromptSubmit и
# PostToolUse (какое именно сработало, берём из .hook_event_name входа).
# Контракт: НИКОГДА не падать и не блокировать сессию (see statusline.sh header).
set -u

THRESH_60='[Контекст: занято %s%%, свободно ~%sk токенов. §13: сделай чекпоинт HANDOFF; новые крупные куски — субагентам или в новую сессию.]'
THRESH_80='[Контекст: занято %s%%, свободно ~%sk токенов. §13: новых M/L-кусков не начинать; доведи текущий до проверяемой точки и обнови HANDOFF.]'
THRESH_90='[Контекст: занято %s%%. §13: немедленно полный pf-handoff (сверка → перезапись → журнал → статусы). Автокомпакт близок — HANDOFF должен быть свежим.]'

run() {
  local input
  input=$(cat)
  [ -z "$input" ] && return 0

  local has_jq=0
  command -v jq >/dev/null 2>&1 && has_jq=1

  local row session_id event transcript_path
  if [ "$has_jq" = 1 ]; then
    row=$(printf '%s' "$input" | jq -r '[(.session_id // ""), (.hook_event_name // ""), (.transcript_path // "")] | @tsv' 2>/dev/null)
  else
    row=$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print("\t".join([str(d.get("session_id") or ""), str(d.get("hook_event_name") or ""), str(d.get("transcript_path") or "")]))
' 2>/dev/null)
  fi
  IFS=$'\t' read -r session_id event transcript_path <<< "$row"
  [ -z "$session_id" ] && return 0
  [ -z "$event" ] && event="UserPromptSubmit"

  local state_dir state_file
  state_dir="$HOME/.claude/context-state"
  state_file="$state_dir/$session_id.json"

  # Значения, которые в итоге пойдут в формулу/сообщение.
  local pct="" window="" used_tokens="" announced=0
  local s_pct="null" s_window="null" s_tokens="null" s_updated="null" s_announced=0

  if [ -f "$state_file" ]; then
    if [ "$has_jq" = 1 ]; then
      row=$(jq -r '[(.pct // "null"), (.window // "null"), (.input_tokens // "null"), (.updated // "null"), (.announced // 0)] | @tsv' "$state_file" 2>/dev/null)
    else
      row=$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
def g(v):
    return "null" if v is None else v
print("\t".join([str(g(d.get("pct"))), str(g(d.get("window"))), str(g(d.get("input_tokens"))), str(g(d.get("updated"))), str(d.get("announced") or 0)]))
' "$state_file" 2>/dev/null)
    fi
    IFS=$'\t' read -r s_pct s_window s_tokens s_updated s_announced <<< "$row"
    [ -z "${s_announced:-}" ] && s_announced=0
    [ "$s_announced" = "null" ] && s_announced=0

    if [ "${s_pct:-null}" != "null" ] && [ -n "${s_pct:-}" ]; then
      local now age
      now=$(date +%s)
      age=$(( now - ${s_updated:-0} ))
      if [ "$age" -le 300 ] 2>/dev/null; then
        pct="$s_pct"; window="$s_window"; used_tokens="$s_tokens"
      fi
    fi
    announced="$s_announced"
  fi

  local fallback_used=0
  if [ -z "$pct" ]; then
    # Состояние отсутствует или устарело (>300с) — резервная эвристика: оценить
    # pct по хвосту транскрипта (последние ~200 КБ, последний блок usage).
    fallback_used=1
    local in_tok=0 cache_creation=0 cache_read=0
    if [ -n "$transcript_path" ] && [ -r "$transcript_path" ]; then
      local usage_line
      usage_line=$(tail -c 200000 -- "$transcript_path" 2>/dev/null | grep '"cache_read_input_tokens"' | tail -1)
      if [ -n "$usage_line" ]; then
        local m
        m=$(printf '%s' "$usage_line" | grep -oE '"input_tokens":[0-9]+' | head -1); in_tok=${m#*:}
        m=$(printf '%s' "$usage_line" | grep -oE '"cache_creation_input_tokens":[0-9]+' | head -1); cache_creation=${m#*:}
        m=$(printf '%s' "$usage_line" | grep -oE '"cache_read_input_tokens":[0-9]+' | head -1); cache_read=${m#*:}
      fi
    fi
    [ -z "$in_tok" ] && in_tok=0
    [ -z "$cache_creation" ] && cache_creation=0
    [ -z "$cache_read" ] && cache_read=0

    # Окно: если в (пусть устаревшем) state-файле оно было — используем его;
    # иначе резервная эвристика по имени модели. UserPromptSubmit/PostToolUse не
    # получают поле model в stdin (его отдаёт только SessionStart), поэтому
    # смотрим на статически сконфигурированную модель в settings.json — это
    # приближение, а не факт текущей сессии.
    if [ "${s_window:-null}" != "null" ] && [ -n "${s_window:-}" ]; then
      window="$s_window"
    else
      window=200000
      local settings_path model_name lc_model
      settings_path="${CLAUDE_SETTINGS_PATH:-$HOME/.claude/settings.json}"
      model_name=""
      if [ -r "$settings_path" ]; then
        if [ "$has_jq" = 1 ]; then
          model_name=$(jq -r '.model // ""' "$settings_path" 2>/dev/null)
        else
          model_name=$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
print(d.get("model") or "")
' "$settings_path" 2>/dev/null)
        fi
      fi
      lc_model=$(printf '%s' "${model_name:-}" | tr '[:upper:]' '[:lower:]')
      case "$lc_model" in
        *'[1m]'*|*fable*|*opus-5*|*sonnet-5*) window=1000000 ;;
        *) window=200000 ;;
      esac
    fi

    used_tokens=$(( in_tok + cache_creation + cache_read ))
    if [ "$window" -gt 0 ] 2>/dev/null; then
      pct=$(( used_tokens * 100 / window ))
    else
      pct=0
    fi
  fi

  [ -z "${pct:-}" ] && return 0

  local new_announced=0
  if [ "$pct" -ge 90 ] 2>/dev/null; then new_announced=90
  elif [ "$pct" -ge 80 ] 2>/dev/null; then new_announced=80
  elif [ "$pct" -ge 60 ] 2>/dev/null; then new_announced=60
  fi

  if [ "$new_announced" -gt 0 ] 2>/dev/null && [ "$new_announced" -gt "${announced:-0}" ] 2>/dev/null; then
    local free_tokens xk msg
    free_tokens=$(( window - used_tokens ))
    [ "$free_tokens" -lt 0 ] && free_tokens=0
    xk=$(( free_tokens / 1000 ))
    case "$new_announced" in
      60) msg=$(printf "$THRESH_60" "$pct" "$xk") ;;
      80) msg=$(printf "$THRESH_80" "$pct" "$xk") ;;
      90) msg=$(printf "$THRESH_90" "$pct") ;;
    esac
    emit_json "$event" "$msg" "$has_jq"
    write_state "$state_dir" "$state_file" "$has_jq" "$fallback_used" "$new_announced" "$pct" "$window" "$used_tokens" "$s_pct" "$s_window" "$s_tokens" "$s_updated"
  elif [ "$pct" -lt 60 ] 2>/dev/null && [ "${announced:-0}" != 0 ]; then
    write_state "$state_dir" "$state_file" "$has_jq" "$fallback_used" 0 "$pct" "$window" "$used_tokens" "$s_pct" "$s_window" "$s_tokens" "$s_updated"
  fi
  return 0
}

emit_json() {
  local event="$1" msg="$2" has_jq="$3"
  if [ "$has_jq" = 1 ]; then
    jq -n --arg name "$event" --arg ctx "$msg" '{hookSpecificOutput: {hookEventName: $name, additionalContext: $ctx}}'
  else
    EAC_EVENT="$event" EAC_MSG="$msg" python3 -c '
import json, os
print(json.dumps({"hookSpecificOutput": {"hookEventName": os.environ["EAC_EVENT"], "additionalContext": os.environ["EAC_MSG"]}}))
'
  fi
}

# write_state — точечно обновляет announced, сохраняя остальные поля состояния.
# Если использовался fallback (state не было/устарело) — пишем свежие
# pct/window/input_tokens/updated; иначе — переносим их из уже прочитанного
# state без изменений (их актуальность — забота statusline.sh).
write_state() {
  local state_dir="$1" state_file="$2" has_jq="$3" fallback_used="$4" ann="$5"
  local fresh_pct="$6" fresh_window="$7" fresh_used="$8"
  local s_pct="$9" s_window="${10}" s_tokens="${11}" s_updated="${12}"
  local out_pct out_window out_tokens out_updated tmp

  if [ "$fallback_used" = 1 ]; then
    out_pct="$fresh_pct"; out_window="$fresh_window"; out_tokens="$fresh_used"; out_updated=$(date +%s)
  else
    out_pct="$s_pct"; out_window="$s_window"; out_tokens="$s_tokens"; out_updated="${s_updated:-$(date +%s)}"
  fi
  [ "$out_updated" = "null" ] && out_updated=$(date +%s)

  mkdir -p "$state_dir" 2>/dev/null
  tmp="$state_dir/.tmp.$$.$RANDOM"
  if [ "$has_jq" = 1 ]; then
    jq -n --argjson pct "$out_pct" --argjson window "$out_window" --argjson input_tokens "$out_tokens" \
          --argjson updated "$out_updated" --argjson announced "$ann" \
      '{pct: $pct, window: $window, input_tokens: $input_tokens, updated: $updated, announced: $announced}' \
      > "$tmp" 2>/dev/null
  else
    python3 -c '
import json, sys
p, w, t, u, a = sys.argv[1:6]
print(json.dumps({"pct": int(p), "window": int(w), "input_tokens": int(t), "updated": int(u), "announced": int(a)}))
' "$out_pct" "$out_window" "$out_tokens" "$out_updated" "$ann" > "$tmp" 2>/dev/null
  fi
  if [ -s "$tmp" ]; then
    mv -f "$tmp" "$state_file"
  else
    rm -f "$tmp" 2>/dev/null
  fi
}

( run ) 2>/dev/null
exit 0
