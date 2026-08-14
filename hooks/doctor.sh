#!/bin/bash
# Health check for the context-hooks install. Prints OK/FAIL per check,
# exit 1 on any FAIL. Operator tool (not a hook) — like install.sh,
# errors are exit 1, not a silent exit 0.
set -u
# $HOME САМ не переопределяем (F-20) — весь внутренний state живёт под
# PF_EFFECTIVE_HOME (тот же контракт, что в statusline.sh/context-guard.sh).
PF_EFFECTIVE_HOME="${HOME:-${TMPDIR:-/tmp}}"

SETTINGS_PATH="${CLAUDE_SETTINGS_PATH:-$PF_EFFECTIVE_HOME/.claude/settings.json}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
STATE_DIR="$PF_EFFECTIVE_HOME/.claude/context-state"

FAIL=0

ok()   { printf 'OK   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; FAIL=1; }

# 1) all seven scripts exist and are executable (autocheckpoint.sh is not a
# registered hook: precompact.sh calls it and blocks compaction when it cannot
# produce a snapshot, so its absence is a real failure, not cosmetic — T-031)
for name in statusline.sh context-guard.sh sessionstart.sh precompact.sh autocheckpoint.sh install.sh doctor.sh; do
  if [ -x "$SCRIPT_DIR/$name" ]; then
    ok "script $name exists and is executable"
  else
    fail "script $name is missing or not executable ($SCRIPT_DIR/$name)"
  fi
done

# 2) settings.json is valid
JSON_READER="none"
if command -v python3 >/dev/null 2>&1; then
  JSON_READER="python3"; json_valid() { python3 -m json.tool "$1" > /dev/null 2>&1; }
elif command -v jq >/dev/null 2>&1; then
  JSON_READER="jq"; json_valid() { jq -e . "$1" > /dev/null 2>&1; }
else
  json_valid() { return 1; }
fi
if [ "$JSON_READER" = "none" ]; then
  fail "cannot check settings.json — neither python3 nor jq is available"
elif json_valid "$SETTINGS_PATH"; then
  ok "settings.json is valid ($SETTINGS_PATH)"
else
  fail "settings.json is invalid or missing ($SETTINGS_PATH)"
fi

# 3) it contains all 5 of our entries (statusLine + 4 hooks).
# Patterns match the file name only, not the directory: the canon keeps the
# scripts in context-hooks/, the public distribution — in hooks/.
if grep -q "/statusline.sh" "$SETTINGS_PATH" 2>/dev/null; then
  ok "statusLine points at our statusline.sh"
else
  fail "statusLine missing / not pointing at our statusline.sh"
fi

if [ "$(grep -o "/context-guard.sh" "$SETTINGS_PATH" 2>/dev/null | wc -l | tr -d ' ')" -ge 2 ] 2>/dev/null; then
  ok "context-guard.sh registered in UserPromptSubmit and PostToolUse"
else
  fail "context-guard.sh not registered (2 occurrences needed: UserPromptSubmit + PostToolUse)"
fi

if grep -q "/sessionstart.sh" "$SETTINGS_PATH" 2>/dev/null; then
  ok "sessionstart.sh registered in SessionStart"
else
  fail "sessionstart.sh not registered in SessionStart"
fi

if grep -q "/precompact.sh" "$SETTINGS_PATH" 2>/dev/null; then
  ok "precompact.sh registered in PreCompact"
else
  fail "precompact.sh not registered in PreCompact"
fi

# 4) Orca compatibility — checked ONLY if Orca is installed on this machine
# (~/.orca/agent-hooks exists). No Orca is not an error: the statusline
# wrapper simply skips the missing script.
if [ -d "$PF_EFFECTIVE_HOME/.orca/agent-hooks" ]; then
  # -o | wc -l, не grep -c: в однострочном settings.json все записи лежат в
  # одной строке, и счётчик строк занижал бы их до 1.
  orca_hook_count=$(grep -o 'claude-hook.sh' "$SETTINGS_PATH" 2>/dev/null | wc -l | tr -d ' ')
  [ -z "$orca_hook_count" ] && orca_hook_count=0
  if [ "$orca_hook_count" -ge 1 ] 2>/dev/null; then
    ok "Orca hooks are in place (claude-hook.sh occurs $orca_hook_count times)"
  else
    fail "Orca is installed but its hooks are absent from settings.json (claude-hook.sh: 0) — check they were not wiped"
  fi
  if [ -f "$SCRIPT_DIR/statusline.sh" ] && grep -q "claude-statusline.sh" "$SCRIPT_DIR/statusline.sh" 2>/dev/null; then
    ok "our statusline.sh still calls Orca's claude-statusline.sh"
  else
    fail "our statusline.sh does not reference Orca's claude-statusline.sh"
  fi
else
  ok "Orca not installed — compatibility checks skipped (that is normal)"
fi

# 5) ~/.claude/context-state/ can be created and written to
if mkdir -p "$STATE_DIR" 2>/dev/null; then
  probe="$STATE_DIR/.doctor-probe.$$"
  if printf 'probe' > "$probe" 2>/dev/null; then
    rm -f "$probe" 2>/dev/null
    ok "$STATE_DIR is creatable and writable"
  else
    fail "$STATE_DIR exists but is not writable"
  fi
else
  fail "$STATE_DIR could not be created"
fi

# 6) status-bar config (optional): present but broken is the one case where
# the user silently gets the defaults and cannot tell why.
SL_CFG="${PF_STATUSLINE_CONFIG:-$PF_EFFECTIVE_HOME/.config/pf-handoff/statusline.json}"
if [ -e "$SL_CFG" ]; then
  if [ "$JSON_READER" = "none" ]; then
    fail "status-bar config exists but cannot be checked — neither python3 nor jq is available ($SL_CFG)"
  elif [ -f "$SL_CFG" ] && json_valid "$SL_CFG"; then
    ok "status-bar config is valid ($SL_CFG)"
  else
    fail "status-bar config exists but does not parse as JSON — statusline silently falls back to defaults; check the syntax with python3 -m json.tool or jq: '$SL_CFG'"
  fi
else
  ok "status-bar config absent — default look (that is normal)"
fi

# 7) auto-compact window (T-031): informational, never a failure. A hook cannot
# start compaction — no such output field exists — so the "compact at 80%" half
# of the design is the harness setting `autoCompactWindow` (tokens, capped at
# the model's context window). Unset is legitimate: the session then compacts
# at the model's limit, and the PreCompact gate still guards that moment.
acw=""
if [ "$JSON_READER" = "python3" ]; then
  acw=$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8-sig"))
except Exception:
    d = {}
print(d.get("autoCompactWindow") or "")
' "$SETTINGS_PATH" 2>/dev/null)
elif [ "$JSON_READER" = "jq" ]; then
  acw=$(jq -r '.autoCompactWindow // ""' "$SETTINGS_PATH" 2>/dev/null)
fi
if [ -n "$acw" ]; then
  ok "autoCompactWindow = $acw tokens (compaction starts there; 800000 = 80% of a 1M window)"
else
  ok "autoCompactWindow unset — compaction at the model's limit (that is the harness default)"
fi

exit "$FAIL"
