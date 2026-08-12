#!/bin/bash
# Пороговые вбросы контекста — одно тело на два события: UserPromptSubmit и
# PostToolUse (какое именно сработало, берём из .hook_event_name входа).
# Контракт: НИКОГДА не падать и не блокировать сессию (see statusline.sh header).
set -u

THRESH_Z1='[Контекст: занято %s%%, свободно ~%sk токенов. §13: сделай чекпоинт HANDOFF; новые крупные куски — субагентам или в новую сессию.]'
THRESH_Z2='[Контекст: занято %s%%, свободно ~%sk токенов. §13: новых M/L-кусков не начинать; доведи текущий до проверяемой точки и обнови HANDOFF.]'
THRESH_Z3='[Контекст: занято %s%%. §13: немедленно полный pf-handoff (сверка → перезапись → журнал → статусы). Автокомпакт близок — HANDOFF должен быть свежим.]'

run() {
  local input
  input=$(cat)
  [ -z "$input" ] && return 0

  local has_jq=0
  command -v jq >/dev/null 2>&1 && has_jq=1

  local row session_id event transcript_path agent_id cwd_in
  if [ "$has_jq" = 1 ]; then
    # Каталог проекта — по той же формуле, что в statusline.sh (сперва
    # workspace.current_dir, потом cwd): иначе два хука читали бы
    # .agents/context-budget.json из разных каталогов.
    # Разделитель U+001F (unit separator), НЕ таб: таб для bash-read — «IFS-пробел»,
    # последовательные табы схлопываются, и пустые поля (например, отсутствующий
    # agent_id) сдвигали бы соседние значения на их место.
    row=$(printf '%s' "$input" | jq -r '[(.session_id // ""), (.hook_event_name // ""), (.transcript_path // ""), (.agent_id // ""), (if (.workspace|type) == "object" then (.workspace.current_dir // .cwd // "") else (.cwd // "") end)] | join("\u001f")' 2>/dev/null)
  else
    row=$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
ws = d.get("workspace")
cwd = (ws.get("current_dir") if isinstance(ws, dict) else None) or d.get("cwd") or ""
print("\x1f".join([str(d.get("session_id") or ""), str(d.get("hook_event_name") or ""), str(d.get("transcript_path") or ""), str(d.get("agent_id") or ""), str(cwd)]))
' 2>/dev/null)
  fi
  IFS=$'\x1f' read -r session_id event transcript_path agent_id cwd_in <<< "$row"
  [ -z "$session_id" ] && return 0
  [ -z "$event" ] && event="UserPromptSubmit"
  # session_id и agent_id становятся именами файлов — только безопасные символы.
  case "$session_id" in *[!A-Za-z0-9._-]*) return 0 ;; esac
  case "${agent_id:-}" in *[!A-Za-z0-9._-]*) return 0 ;; esac

  # Субагентский вызов (во входе есть agent_id): процент РОДИТЕЛЯ для субагента —
  # дезинформация (у него своё, отдельное окно), а расход родительского
  # `announced` прятал бы предупреждение от самого родителя. Поэтому: считаем
  # собственное окно субагента по его транскрипту (путь вычислим по шаблону
  # <каталог>/<session_id>/subagents/agent-<agent_id>.jsonl) и ведём отдельный
  # state-ключ agent-<id>.json. Родительское состояние не читаем и не пишем.
  # Оговорка: окно для fallback берётся по модели из settings.json — если
  # субагент на другой модели (например haiku, 200k), оценка приблизительная.
  if [ -n "$agent_id" ]; then
    local sub_tp
    sub_tp="$(dirname "$transcript_path")/$session_id/subagents/agent-$agent_id.jsonl"
    if [ ! -r "$sub_tp" ]; then
      # Страховка на случай смены структуры каталогов harness'ом: сегодня ВСЕ
      # уровни вложенности (сын, внук, …) лежат плоско в subagents/ главной
      # сессии — проверено экспериментом с внуком 2026-08-10.
      sub_tp=$(find "$(dirname "$transcript_path")/$session_id" -maxdepth 4 -name "agent-$agent_id.jsonl" 2>/dev/null | head -n 1)
    fi
    { [ -n "$sub_tp" ] && [ -r "$sub_tp" ]; } || return 0
    transcript_path="$sub_tp"
    session_id="agent-$agent_id"
  fi

  # Пороги зон: по умолчанию 60/80/90, проект может переопределить файлом
  # <cwd>/.agents/context-budget.json вида {"thresholds": [50, 70, 85]}
  # (ровно три целых 1–99 по возрастанию; иначе — молча дефолт).
  local t1=60 t2=80 t3=90
  local cfg="$cwd_in/.agents/context-budget.json"
  if [ -n "$cwd_in" ] && [ -f "$cfg" ] && [ -r "$cfg" ]; then
    local trow=""
    if [ "$has_jq" = 1 ]; then
      trow=$(jq -r 'if (.thresholds|type)=="array" and (.thresholds|length)==3 then (.thresholds|map(tostring)|join("\t")) else "" end' "$cfg" 2>/dev/null)
    else
      trow=$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8-sig"))
    t = d.get("thresholds")
    assert isinstance(t, list) and len(t) == 3
    # str(x), НЕ str(int(x)): целочисленность проверяет bash ниже — так ветка
    # без jq отвергает дробные ровно как ветка с jq (и как statusline.sh).
    print("\t".join(str(x) for x in t))
except Exception:
    print("")
' "$cfg" 2>/dev/null)
    fi
    if [ -n "$trow" ]; then
      local c1 c2 c3
      IFS=$'\t' read -r c1 c2 c3 <<< "$trow"
      # Сначала «только цифры», как в statusline.sh: `test -ge` терпит пробелы и
      # знак (" 50", "+50"), поэтому без этого фильтра guard принимал конфиги,
      # которые статус-строка отвергает, и зоны бара расходились с директивами.
      case "$c1$c2$c3" in
        *[!0-9]*|'') : ;;
        *)
          if [ "$c1" -ge 1 ] 2>/dev/null && [ "$c1" -lt "$c2" ] 2>/dev/null && [ "$c2" -lt "$c3" ] 2>/dev/null && [ "$c3" -le 99 ] 2>/dev/null; then
            t1="$c1"; t2="$c2"; t3="$c3"
          fi ;;
      esac
    fi
  fi

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
    d = json.load(open(sys.argv[1], encoding="utf-8-sig"))
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
    d = json.load(open(sys.argv[1], encoding="utf-8-sig"))
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

  local new_announced=0 zone=0
  if [ "$pct" -ge "$t3" ] 2>/dev/null; then new_announced=$t3; zone=3
  elif [ "$pct" -ge "$t2" ] 2>/dev/null; then new_announced=$t2; zone=2
  elif [ "$pct" -ge "$t1" ] 2>/dev/null; then new_announced=$t1; zone=1
  fi

  if [ "$new_announced" -gt 0 ] 2>/dev/null && [ "$new_announced" -gt "${announced:-0}" ] 2>/dev/null; then
    local free_tokens xk msg
    free_tokens=$(( window - used_tokens ))
    [ "$free_tokens" -lt 0 ] && free_tokens=0
    xk=$(( free_tokens / 1000 ))
    case "$zone" in
      1) msg=$(printf "$THRESH_Z1" "$pct" "$xk") ;;
      2) msg=$(printf "$THRESH_Z2" "$pct" "$xk") ;;
      3) msg=$(printf "$THRESH_Z3" "$pct") ;;
    esac
    emit_json "$event" "$msg" "$has_jq"
    write_state "$state_dir" "$state_file" "$has_jq" "$fallback_used" "$new_announced" "$pct" "$window" "$used_tokens" "$s_pct" "$s_window" "$s_tokens" "$s_updated"
  elif [ "$pct" -lt "$t1" ] 2>/dev/null && [ "${announced:-0}" != 0 ]; then
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
