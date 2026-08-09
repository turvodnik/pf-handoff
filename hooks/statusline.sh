#!/bin/bash
# statusLine-обёртка Claude Code.
# Контракт: НИКОГДА не падать (set -u, но без set -e; вся логика — в подоболочке,
# чтобы даже фатальная ошибка "unbound variable" не уронила финальный exit 0).
# 1) прочитать stdin один раз; 2) прогнать его через орковский statusline (для
#    его собственной телеметрии, вывод подавляем); 3) распарсить context_window
#    и напечатать свою строку; 4) атомарно сохранить состояние сессии для
#    context-guard.sh.
set -u

# Путь переопределяем только для тестов (фикстура "орковский скрипт отсутствует"
# без переименования реального файла Orca — чужие файлы ~/.orca/agent-hooks/*
# не трогаем). По умолчанию — стандартный путь Orca; нет Orca — условие ниже
# просто пропустит вызов, наша часть работает без изменений.
ORCA_STATUSLINE="${CONTEXT_HOOKS_ORCA_STATUSLINE:-$HOME/.orca/agent-hooks/claude-statusline.sh}"

run() {
  local input
  input=$(cat)
  [ -z "$input" ] && return 0

  # Орковский statusline вызываем тем же защитным условием, что и в settings.json
  # (существует/читаем/исполняем — иначе пропустить). Его stdout/stderr подавляем:
  # он используется только ради побочного эффекта (телеметрия rate_limits в Orca),
  # печатать свою строку статуса — наша задача.
  if [ -f "$ORCA_STATUSLINE" ] && [ -r "$ORCA_STATUSLINE" ] && [ -x "$ORCA_STATUSLINE" ]; then
    printf '%s' "$input" | /bin/sh "$ORCA_STATUSLINE" >/dev/null 2>&1
  fi

  local has_jq=0
  command -v jq >/dev/null 2>&1 && has_jq=1

  local row session_id pct_raw window_raw tokens_raw model_name
  if [ "$has_jq" = 1 ]; then
    row=$(printf '%s' "$input" | jq -r '
      [
        (.session_id // ""),
        (if (.context_window|type) == "object" then (.context_window.used_percentage // "null") else "null" end),
        (if (.context_window|type) == "object" then (.context_window.context_window_size // "null") else "null" end),
        (if (.context_window|type) == "object" then (.context_window.total_input_tokens // "null") else "null" end),
        (.model.display_name // "")
      ] | map(tostring) | join("\u001f")
    ' 2>/dev/null)
  else
    row=$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
cw = d.get("context_window")
if not isinstance(cw, dict):
    cw = {}
def g(v):
    return "null" if v is None else v
row = [
    str(d.get("session_id") or ""),
    str(g(cw.get("used_percentage"))),
    str(g(cw.get("context_window_size"))),
    str(g(cw.get("total_input_tokens"))),
    str((d.get("model") or {}).get("display_name") or ""),
]
print("\x1f".join(row))
' 2>/dev/null)
  fi

  IFS=$'\x1f' read -r session_id pct_raw window_raw tokens_raw model_name <<< "$row"

  # context_window отсутствует/null (или в нём нет used_percentage/размера) —
  # печатаем только модель, состояние сессии не пишем (пороги считать не от чего).
  if [ "${pct_raw:-null}" = "null" ] || [ "${window_raw:-null}" = "null" ]; then
    printf '⛽ %s\n' "${model_name:-?}"
    return 0
  fi

  local pct_int tokens_int tokens_k win_label
  pct_int=$(printf '%s' "$pct_raw" | cut -d. -f1)
  [ -z "$pct_int" ] && pct_int=0
  tokens_int=$(printf '%s' "${tokens_raw:-0}" | cut -d. -f1)
  [ -z "$tokens_int" ] && tokens_int=0
  tokens_k=$(( tokens_int / 1000 ))

  if [ "$window_raw" = "1000000" ]; then
    win_label="1M"
  else
    win_label="200k"
  fi

  printf '⛽ %s%% · %sk/%s · %s\n' "$pct_int" "$tokens_k" "$win_label" "${model_name:-?}"

  [ -z "$session_id" ] && return 0

  local state_dir tmp now
  state_dir="$HOME/.claude/context-state"
  mkdir -p "$state_dir" 2>/dev/null
  now=$(date +%s)
  tmp="$state_dir/.tmp.$$.$RANDOM"

  if [ "$has_jq" = 1 ]; then
    jq -n --argjson pct "$pct_int" --argjson window "$window_raw" \
          --argjson input_tokens "$tokens_int" --argjson updated "$now" \
      '{pct: $pct, window: $window, input_tokens: $input_tokens, updated: $updated}' \
      > "$tmp" 2>/dev/null
  else
    python3 -c '
import json, sys
pct, window, tok, upd = sys.argv[1:5]
print(json.dumps({"pct": int(pct), "window": int(window), "input_tokens": int(tok), "updated": int(upd)}))
' "$pct_int" "$window_raw" "$tokens_int" "$now" > "$tmp" 2>/dev/null
  fi

  if [ -s "$tmp" ]; then
    mv -f "$tmp" "$state_dir/$session_id.json"
  else
    rm -f "$tmp" 2>/dev/null
  fi
  return 0
}

( run ) 2>/dev/null
exit 0
