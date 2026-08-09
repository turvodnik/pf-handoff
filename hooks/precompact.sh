#!/bin/bash
# Лог компактов: PreCompact не поддерживает additionalContext (только decision/
# block, docs code.claude.com/docs/en/hooks.md) — блокировать компакт нельзя и
# не нужно, поэтому этот хук только дописывает строку в лог.
# Контракт: НИКОГДА не падать и не блокировать сессию (see statusline.sh header).
set -u

run() {
  local input
  input=$(cat)
  [ -z "$input" ] && return 0

  local has_jq=0
  command -v jq >/dev/null 2>&1 && has_jq=1

  local row session_id trigger cwd_in
  if [ "$has_jq" = 1 ]; then
    row=$(printf '%s' "$input" | jq -r '[(.session_id // ""), (.trigger // ""), (.cwd // "")] | @tsv' 2>/dev/null)
  else
    row=$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print("\t".join([str(d.get("session_id") or ""), str(d.get("trigger") or ""), str(d.get("cwd") or "")]))
' 2>/dev/null)
  fi
  IFS=$'\t' read -r session_id trigger cwd_in <<< "$row"

  local ts log_dir
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  log_dir="$HOME/.claude/context-state"
  mkdir -p "$log_dir" 2>/dev/null
  printf '%s %s %s %s\n' "$ts" "${session_id:-?}" "${trigger:-?}" "${cwd_in:-?}" >> "$log_dir/compacts.log"
  return 0
}

( run ) 2>/dev/null
exit 0
