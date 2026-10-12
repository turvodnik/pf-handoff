#!/bin/bash
# Пороговые вбросы контекста — одно тело на два события: UserPromptSubmit и
# PostToolUse (какое именно сработало, берём из .hook_event_name входа).
# Контракт: НИКОГДА не падать и не блокировать сессию (see statusline.sh header).
set -u
# Дочерний CLI council.sh (PF_COUNCIL_RUN=1) — одноразовый процесс с одним
# заданием: пороговые вбросы и снимки ему не нужны, а его вывод — чужой отчёт.
# Молчим: вход сливаем, rc 0 (QA 2.0.0, тихий режим).
if [ "${PF_COUNCIL_RUN:-}" = 1 ]; then cat >/dev/null 2>&1; exit 0; fi
# Контракт «никогда не мешать сессии»: без HOME не выключаемся молча, а
# уходим во временный каталог (та же страховка, что в statusline.sh).
# $HOME САМ не переопределяем (F-20) — весь внутренний state живёт под
# PF_EFFECTIVE_HOME (см. statusline.sh, тот же контракт).
PF_EFFECTIVE_HOME="${HOME:-${TMPDIR:-/tmp}}"
HOOK_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"

THRESH_Z1='[Контекст: занято %s%%, свободно ~%sk токенов. §13: короткий чекпоинт HANDOFF (≈10 строк: цель, шаг, доказано, не делать); новые крупные куски — субагентам или в новую сессию.]'
THRESH_Z2='[Контекст: занято %s%%, свободно ~%sk токенов. §13: полный pf-handoff; новых M/L не начинать; доведи текущий кусок до проверяемой точки.]'
THRESH_Z3='[Контекст: занято %s%%. §13: финальный pf-handoff; доведи шаг до проверяемой точки (сжатие платформы — на пороге /autocompact: 80 %% окна 1M, 90 %% окна 200k).]'
# Хвосты второй зоны (T-031): на пороге t2 снимок состояния пишется САМ
# (autocheckpoint.sh), и агенту сообщается ФАКТ — записан или нет. Сжатие хук
# инициировать не может ни в каком виде (у хуков нет такого поля вывода), его
# на 80% окна 1M (90% окна 200k) запускает сам харнесс (настройка autoCompactWindow / /autocompact); задача этого
# сообщения — чтобы сжатие не застало состояние несохранённым.
# T-154 (A1): the same two tails go after the zone-3 text when t2 is crossed by
# a jump straight into zone 3 — see the snapshot block in run().
THRESH_Z2_OK=' Авто-снимок состояния записан сам: %s. Смысловой чекпоинт всё равно за тобой: сделай pf-handoff — снимок собран скриптом и не отличает доказанное от заявленного.'
THRESH_Z2_FAIL=' ВНИМАНИЕ: авто-снимок состояния записать НЕ УДАЛОСЬ. Сжимать контекст нельзя (/compact и /clear запрещены), пока состояние не сохранено руками через pf-handoff: сжатие с потерей состояния хуже, чем его отсутствие (I-036). PreCompact заблокирует автосжатие до починки записи.'
# transcript_usage TRANSCRIPT HAS_JQ — prints "<top_total>\t<corrected_total>"
# from the last usage block in the transcript tail, or nothing.
# top_total       = input + cache_creation + cache_read as the API reports them
#                   (this is also what the harness shows as context usage);
# corrected_total = the same sum from the LAST `type: "message"` entry of
#                   usage.iterations when there is more than one iteration.
# Why: a turn that calls the server-side `advisor` tool is billed as several
# iterations (main model -> advisor -> main model) and the top-level usage is
# their SUM — about 2x the real context (a client project, 2026-09-16: 515 357 -> 1 033 942
# in one turn, every advisor turn in 171/172 transcripts). The harness, the
# status line and the old guard all read the doubled value, so the guard
# jumped 51 % -> "100 %" and skipped t2. Without `iterations` (an honest
# reading) both numbers are equal and nothing changes.
transcript_usage() {
  local tp="$1" has_jq="$2" usage_line parsed
  { [ -n "$tp" ] && [ -r "$tp" ]; } || return 0
  usage_line=$(tail -c 200000 -- "$tp" 2>/dev/null | grep '"cache_read_input_tokens"' | tail -1)
  [ -z "$usage_line" ] && return 0
  parsed=$(transcript_usage_parse "$usage_line" "$has_jq")
  if [ -n "$parsed" ]; then
    printf '%s' "$parsed"
    return 0
  fi
  # The structured parse failed — typically the line was cut by `tail -c`
  # (a tool result larger than 200 KB; usage sits at the END of the JSON, so
  # the numbers survive the cut). Same three greps the pre-T-111 fallback
  # used; no iterations are visible this way, so corrected = top.
  local m in_tok cache_creation cache_read
  m=$(printf '%s' "$usage_line" | grep -oE '"input_tokens":[0-9]+' | head -1); in_tok=${m#*:}
  m=$(printf '%s' "$usage_line" | grep -oE '"cache_creation_input_tokens":[0-9]+' | head -1); cache_creation=${m#*:}
  m=$(printf '%s' "$usage_line" | grep -oE '"cache_read_input_tokens":[0-9]+' | head -1); cache_read=${m#*:}
  local top=$(( ${in_tok:-0} + ${cache_creation:-0} + ${cache_read:-0} ))
  printf '%s\t%s' "$top" "$top"
}

transcript_usage_parse() {
  local usage_line="$1" has_jq="$2"
  if [ "$has_jq" = 1 ]; then
    printf '%s' "$usage_line" | jq -r '
      def tot: ((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0));
      (.message.usage // {}) as $u
      | ($u | tot) as $top
      | (if ($u.iterations|type) == "array" and ($u.iterations|length) > 1
         then ([$u.iterations[] | select(.type == "message")] | if length > 0 then (last | tot) else $top end)
         else $top end) as $corr
      | "\($top)\t\($corr)"' 2>/dev/null
  else
    printf '%s' "$usage_line" | python3 -c '
import json, sys
try:
    u = (json.load(sys.stdin).get("message") or {}).get("usage") or {}
except Exception:
    sys.exit(0)
def tot(x):
    return int(x.get("input_tokens") or 0) + int(x.get("cache_creation_input_tokens") or 0) + int(x.get("cache_read_input_tokens") or 0)
top = tot(u)
corr = top
it = u.get("iterations")
if isinstance(it, list) and len(it) > 1:
    msgs = [x for x in it if isinstance(x, dict) and x.get("type") == "message"]
    if msgs:
        corr = tot(msgs[-1])
print("%d\t%d" % (top, corr))
' 2>/dev/null
  fi
}

# transcript_model TRANSCRIPT HAS_JQ — prints the model of the last assistant
# reply in the transcript tail (`.message.model`, e.g. "claude-opus-5-5"), or
# nothing. `<synthetic>` records (Claude Code writes them after an interrupt or
# an API error) are not a model and are skipped, and so are sidechain records.
# A structured parse on purpose: a bare grep for "model":"…" would also catch a
# tool input such as the Agent tool's {"model":"sonnet"}. A line cut by
# `tail -c` does not parse and is skipped: its `model` comes first in
# `message`, so a reply longer than the tail (a big Write input or answer)
# loses it — then a second, 2 MB tail reaches the record's start (Codex P2).
transcript_model() {
  local tp="$1" has_jq="$2" size m
  { [ -n "$tp" ] && [ -r "$tp" ]; } || return 0
  for size in 200000 2000000; do
    m=$(transcript_model_tail "$tp" "$has_jq" "$size")
    if [ -n "$m" ]; then printf '%s' "$m"; return 0; fi
  done
  return 0
}

transcript_model_tail() {
  local tp="$1" has_jq="$2" size="$3"
  if [ "$has_jq" = 1 ]; then
    tail -c "$size" -- "$tp" 2>/dev/null | grep '"model"' \
      | jq -R -r 'fromjson? | select(type == "object" and .type == "assistant" and .isSidechain != true) | (.message | objects | .model | strings) | select(length > 0 and (startswith("<") | not))' 2>/dev/null \
      | tail -n 1
  else
    tail -c "$size" -- "$tp" 2>/dev/null | grep '"model"' | python3 -c '
import json, sys
last = ""
for line in sys.stdin:
    try:
        d = json.loads(line)
    except Exception:
        continue
    if not isinstance(d, dict) or d.get("type") != "assistant" or d.get("isSidechain") is True:
        continue
    m = d.get("message")
    if isinstance(m, dict) and isinstance(m.get("model"), str) and m["model"] and not m["model"].startswith("<"):
        last = m["model"]
print(last)
' 2>/dev/null
  fi
}

run() {
  local input
  input=$(cat)
  [ -z "$input" ] && return 0

  local has_jq=0
  command -v jq >/dev/null 2>&1 && has_jq=1

  local row session_id event transcript_path agent_id cwd_in
  if [ "$has_jq" = 1 ]; then
    # Каталог проекта — по той же формуле, что в statusline.sh (сперва
    # workspace.current_dir, потом cwd).
    # Разделитель U+001F (unit separator), НЕ таб: таб для bash-read — «IFS-пробел»,
    # последовательные табы схлопываются, и пустые поля (например, отсутствующий
    # agent_id) сдвигали бы соседние значения на их место.
    row=$(printf '%s' "$input" | jq -r '[(.session_id // ""), (.hook_event_name // ""), (.transcript_path // ""), (.agent_id // ""), (if (.workspace|type) == "object" and ((.workspace.current_dir // "") != "") then .workspace.current_dir else (.cwd // "") end)] | join("\u001f")' 2>/dev/null)
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
  # session_id становится именем файла — только безопасные символы.
  case "$session_id" in *[!A-Za-z0-9._-]*) return 0 ;; esac

  # Subagent (T-154, audit 02.10 Н1б/Н4а): no threshold directives at all. A
  # directive told a subagent to "сделай чекпоинт HANDOFF", which the rules do
  # not allow it (HANDOFF belongs to the task owner; autocheckpoint.sh skips
  # agent-* on purpose) — 139 of 146 subagents ignored it, and a subagent's
  # window is not the human's concern (the harness compacts it by itself).
  # Either sign is enough: `agent_id` in the hook input, or the subagent's own
  # transcript (<dir>/<session_id>/subagents/agent-<id>.jsonl). Nothing is read
  # or written — neither the parent's state nor one of its own.
  [ -n "${agent_id:-}" ] && return 0
  case "${transcript_path:-}" in */subagents/agent-*.jsonl) return 0 ;; esac

  # Пороги зон: по умолчанию 40/60/75 % ОКНА модели. Переопределение — только
  # переменная окружения CONTEXT_GUARD_THRESHOLDS: три целых через пробел по
  # возрастанию, каждое 1–99 ("30 50 70"). Любое иное значение — молча дефолт.
  # statusline.sh разбирает её тем же кодом (иначе бар и директивы разойдутся).
  local t1=40 t2=60 t3=75
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
              t1="$c1"; t2="$c2"; t3="$c3"
            fi
          fi ;;
      esac
    fi
  fi

  local state_dir state_file
  state_dir="$PF_EFFECTIVE_HOME/.claude/context-state"
  state_file="$state_dir/$session_id.json"

  # Значения, которые в итоге пойдут в формулу/сообщение.
  local pct="" window="" used_tokens="" announced=0
  local s_pct="null" s_window="null" s_tokens="null" s_updated="null" s_announced=0 s_wguess=0 s_sver=0

  if [ -f "$state_file" ]; then
    if [ "$has_jq" = 1 ]; then
      row=$(jq -r '[(.pct // "null"), (.window // "null"), (.input_tokens // "null"), (.updated // "null"), (.announced // 0), (.window_guess // 0), (.state_version // 0)] | map(tostring) | map(gsub("[\u0000-\u001F\u007F]"; " ")) | join("\t")' "$state_file" 2>/dev/null)
    else
      row=$(python3 -c '
import json, sys, re
try:
    d = json.load(open(sys.argv[1], encoding="utf-8-sig"))
except Exception:
    d = {}
def g(v):
    return "null" if v is None else v
row = [str(g(d.get("pct"))), str(g(d.get("window"))), str(g(d.get("input_tokens"))), str(g(d.get("updated"))), str(d.get("announced") or 0), str(d.get("window_guess") or 0), str(d.get("state_version") or 0)]
print("\t".join(re.sub(r"[\x00-\x1f\x7f]", " ", x) for x in row))
' "$state_file" 2>/dev/null)
    fi
    IFS=$'\t' read -r s_pct s_window s_tokens s_updated s_announced s_wguess s_sver <<< "$row"
    [ -z "${s_announced:-}" ] && s_announced=0
    [ "${s_wguess:-0}" = 1 ] || s_wguess=0
    # A state without state_version: 2 was written by v1.10.0 or older, whose
    # guard stored its guess by the settings alias (200000 for `opus`) with no
    # mark at all — its window is a guess, never the status line's number
    # (QA 2.0.0, N2). Version 2 is written by this guard and status line; a
    # higher one (a future schema) is not a guess either.
    case "${s_sver:-}" in ''|*[!0-9]*) s_sver=0 ;; esac
    [ "$s_sver" -ge 2 ] || s_wguess=1
    [ "$s_announced" = "null" ] && s_announced=0
    if [ "${s_pct:-null}" != "null" ] && [ -n "${s_pct:-}" ]; then
      local now age
      now=$(date +%s)
      age=$(( now - ${s_updated:-0} ))
      # A FRESH state is taken as is only in the new schema: a v1.10.0 state
      # may hold that guard's alias guess (200000 for `opus`) — it goes to the
      # fallback below like a stale one (QA 2.0.0, N2, fix round 1).
      if [ "$age" -le 300 ] 2>/dev/null && [ "$s_sver" -ge 2 ]; then
        pct="$s_pct"; window="$s_window"; used_tokens="$s_tokens"
      fi
    fi
    announced="$s_announced"
  fi

  # Last usage block of the transcript: "<top>\t<corrected>" (see
  # transcript_usage). Read once, used by the fallback below and by the
  # advisor-spike correction of a fresh state.
  local tu_top="" tu_corr=""
  IFS=$'\t' read -r tu_top tu_corr <<< "$(transcript_usage "${transcript_path:-}" "$has_jq")"
  case "${tu_top:-}" in ''|*[!0-9]*) tu_top=""; tu_corr="" ;; esac
  case "${tu_corr:-}" in ''|*[!0-9]*) tu_top=""; tu_corr="" ;; esac

  local fallback_used=0 window_src="statusline" model_name=""
  if [ -z "$pct" ]; then
    # Состояние отсутствует или устарело (>300с) — резервная эвристика: оценить
    # pct по хвосту транскрипта (последние ~200 КБ, последний блок usage).
    fallback_used=1
    # The corrected total (last main-model iteration) is the real context; on
    # an honest turn it equals the top-level sum, so nothing changes there.
    local est_tokens="${tu_corr:-0}"

    # Window (T-154, audit 02.10 Н1; QA 2.0.0 Y9). Never from the `.model`
    # alias of the settings file: `/model` rewrites that alias (`opus[1m]` ->
    # `opus` -> `fable`), and with `opus` the guard took 200k for a 1M model.
    # Order:
    #   1. the window of the (stale) state when the STATUS LINE wrote it — the
    #      harness's own number, so it wins over any guess by model name: a
    #      family-5 model can run with a 200k window (QA 2.0.0, Y9);
    #   2. family 5 (claude-<name>-5, claude-<name>-5-…) -> 1M is assumed;
    #   3. any other model -> a window this guard guessed and wrote earlier
    #      (window_guess: 1 in the state), when there is one;
    #   4. otherwise 1M, marked «предположено» in the debug line. Too large a
    #      window means a late warning, too small means false alarms (Vladimir 03.10).
    # A window the guard itself guessed is stored with window_guess: 1, so it
    # is never mistaken for the status line's number on the next call; a
    # state with no state_version: 2 (v1.10.0 and older) counts as a guess.
    # The family pattern is anchored on purpose: claude-haiku-4-5-20251001
    # contains "-5" and must not read as family 5.
    model_name=$(transcript_model "${transcript_path:-}" "$has_jq")
    local lc_model re5='^claude-[a-z]+-5([^0-9]|$)' s_win_ok=0
    lc_model=$(printf '%s' "$model_name" | tr '[:upper:]' '[:lower:]')
    case "${s_window:-}" in
      ''|*[!0-9]*) : ;;
      *) [ "$s_window" -gt 0 ] 2>/dev/null && s_win_ok=1 ;;
    esac
    if [ "$s_win_ok" = 1 ] && [ "$s_wguess" != 1 ]; then
      window="$s_window"; window_src="state"
    elif [[ "$lc_model" =~ $re5 ]]; then
      window=1000000; window_src="model"
    elif [ "$s_win_ok" = 1 ]; then
      window="$s_window"; window_src="guess"
    else
      window=1000000; window_src="assumed"
    fi

    used_tokens="$est_tokens"
    if [ "$window" -gt 0 ] 2>/dev/null; then
      pct=$(( used_tokens * 100 / window ))
    else
      pct=0
    fi
  elif [ -n "$tu_top" ] && [ "$tu_top" != "$tu_corr" ] && [ "${used_tokens:-x}" = "$tu_top" ]; then
    # Fresh state, but statusline.sh stored exactly the doubled top-level sum
    # of an advisor turn (the harness reports it as context usage): take the
    # real context from the last main-model iteration instead. The match is
    # exact on purpose — a state written after a later honest turn no longer
    # equals the spike and is left alone.
    used_tokens="$tu_corr"
    if [ "$window" -gt 0 ] 2>/dev/null; then
      pct=$(( used_tokens * 100 / window ))
    else
      pct=0
    fi
  fi

  [ -z "${pct:-}" ] && return 0

  # Debug (T-154): CONTEXT_GUARD_DEBUG=1 prints one line on the hook's
  # ORIGINAL stderr (fd 3, see the last lines) — which window was used and
  # where it came from. Read-only: it changes no decision.
  if [ "${CONTEXT_GUARD_DEBUG:-}" = 1 ]; then
    local src_text
    case "$window_src" in
      model)   src_text="по модели транскрипта" ;;
      state)   src_text="из состояния статус-строки" ;;
      guess)   src_text="из прошлой оценки guard (модель не из семейства 5)" ;;
      assumed) if [ -n "$model_name" ]; then src_text="предположено: модель неизвестна"
               else src_text="предположено: модели в транскрипте нет"; fi ;;
      *)       src_text="из свежего состояния статус-строки" ;;
    esac
    printf 'context-guard: окно %s (%s); модель %s; токенов %s; занято %s%%\n' \
      "$window" "$src_text" "${model_name:-—}" "${used_tokens:-?}" "$pct" >&3
  fi

  local new_announced=0 zone=0
  if [ "$pct" -ge "$t3" ] 2>/dev/null; then new_announced=$t3; zone=3
  elif [ "$pct" -ge "$t2" ] 2>/dev/null; then new_announced=$t2; zone=2
  elif [ "$pct" -ge "$t1" ] 2>/dev/null; then new_announced=$t1; zone=1
  fi

  # Everything below builds up to ONE emit (context directive) and ONE state write.
  local out_announced="${announced:-0}" need_write=0 msg=""

  if [ "$new_announced" -gt 0 ] 2>/dev/null && [ "$new_announced" -gt "${announced:-0}" ] 2>/dev/null; then
    local free_tokens xk
    free_tokens=$(( window - used_tokens ))
    [ "$free_tokens" -lt 0 ] && free_tokens=0
    xk=$(( free_tokens / 1000 ))
    case "$zone" in
      1) msg=$(printf "$THRESH_Z1" "$pct" "$xk") ;;
      2) msg=$(printf "$THRESH_Z2" "$pct" "$xk") ;;
      3) msg=$(printf "$THRESH_Z3" "$pct") ;;
    esac
    # Порог t2 — единственная точка, где чекпоинт выполняется без спроса.
    # Порог t2 общий с зонами выше (по умолчанию 60 % окна, переопределение —
    # CONTEXT_GUARD_THRESHOLDS).
    # A1 (T-154, audit 02.10 Н4б): the snapshot follows the FIRST crossing of
    # t2, not the zone-2 branch — a jump 59->95 or 79->95 (one big tool
    # result) used to land in zone 3 and get the order with no snapshot.
    # "First" = nothing at or above t2 announced since the last reset below t1,
    # so a repeat (95->96) or 85->95 after the t2 snapshot writes none.
    if [ "$zone" -ge 2 ] && [ "${announced:-0}" -lt "$t2" ] 2>/dev/null; then
      local snap ac_rc ac
      ac="$HOOK_DIR/autocheckpoint.sh"
      snap=""; ac_rc=1
      if [ -f "$ac" ] && [ -r "$ac" ]; then
        snap=$(bash "$ac" --session "$session_id" --cwd "${cwd_in:-}" \
                 --transcript "${transcript_path:-}" \
                 --reason "порог t2 ($pct%)" 2>/dev/null)
        ac_rc=$?
      fi
      if [ "$ac_rc" -eq 0 ] && [ -n "$snap" ]; then
        msg="$msg$(printf "$THRESH_Z2_OK" "$snap")"
      elif [ "$ac_rc" -eq 0 ]; then
        : # осознанный пропуск (субагент) — молча, это не отказ
      else
        msg="$msg$THRESH_Z2_FAIL"
      fi
    fi
    out_announced="$new_announced"; need_write=1
  elif [ "$pct" -lt "$t1" ] 2>/dev/null && [ "${announced:-0}" != 0 ]; then
    out_announced=0; need_write=1
  fi

  if [ -n "$msg" ]; then emit_json "$event" "$msg" "$has_jq"; fi
  if [ "$need_write" = 1 ]; then
    local out_wguess="$s_wguess"
    if [ "$fallback_used" = 1 ]; then
      case "$window_src" in state) out_wguess=0 ;; *) out_wguess=1 ;; esac
    fi
    write_state "$state_dir" "$state_file" "$has_jq" "$fallback_used" "$out_announced" "$pct" "$window" "$used_tokens" "$s_pct" "$s_window" "$s_tokens" "$s_updated" "$out_wguess"
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
print(json.dumps({"hookSpecificOutput": {"hookEventName": os.environ["EAC_EVENT"], "additionalContext": os.environ["EAC_MSG"]}}, ensure_ascii=False))
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
  local s_pct="$9" s_window="${10}" s_tokens="${11}" s_updated="${12}" wguess="${13:-0}"
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
          --argjson updated "$out_updated" --argjson announced "$ann" --argjson wguess "$wguess" \
      '{pct: $pct, window: $window, input_tokens: $input_tokens, updated: $updated, announced: $announced, state_version: 2} + (if $wguess == 1 then {window_guess: 1} else {} end)' \
      > "$tmp" 2>/dev/null
  else
    python3 -c '
import json, sys
p, w, t, u, a, g = sys.argv[1:7]
d = {"pct": int(p), "window": int(w), "input_tokens": int(t), "updated": int(u), "announced": int(a), "state_version": 2}
if g == "1":
    d["window_guess"] = 1
print(json.dumps(d))
' "$out_pct" "$out_window" "$out_tokens" "$out_updated" "$ann" "$wguess" > "$tmp" 2>/dev/null
  fi
  if [ -s "$tmp" ]; then
    mv -f "$tmp" "$state_file"
  else
    rm -f "$tmp" 2>/dev/null
  fi
}

# fd 3 keeps the original stderr for the opt-in debug line; everything else
# on stderr stays silenced (the hook must never disturb the session). fd 3 is
# opened only in debug mode: with a closed stderr `3>&2` would fail and the
# guard would silently not run, and children need not inherit the hook's stderr.
if [ "${CONTEXT_GUARD_DEBUG:-}" = 1 ]; then
  ( run ) 3>&2 2>/dev/null
else
  ( run ) 2>/dev/null
fi
exit 0
