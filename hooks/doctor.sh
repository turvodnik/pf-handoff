#!/bin/bash
# Health check for the context-hooks install. Prints OK/FAIL per check,
# exit 1 on any FAIL. Operator tool (not a hook) — like install.sh,
# errors are exit 1, not a silent exit 0.
set -u

SETTINGS_PATH="${CLAUDE_SETTINGS_PATH:-$HOME/.claude/settings.json}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
STATE_DIR="$HOME/.claude/context-state"

FAIL=0

ok()   { printf 'OK   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; FAIL=1; }

# 1) all six scripts exist and are executable
for name in statusline.sh context-guard.sh sessionstart.sh precompact.sh install.sh doctor.sh; do
  if [ -x "$SCRIPT_DIR/$name" ]; then
    ok "script $name exists and is executable"
  else
    fail "script $name is missing or not executable ($SCRIPT_DIR/$name)"
  fi
done

# 2) settings.json is valid
if python3 -m json.tool "$SETTINGS_PATH" > /dev/null 2>&1; then
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

if [ "$(grep -c "/context-guard.sh" "$SETTINGS_PATH" 2>/dev/null || echo 0)" -ge 2 ] 2>/dev/null; then
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
if [ -d "$HOME/.orca/agent-hooks" ]; then
  orca_hook_count=$(grep -c 'claude-hook.sh' "$SETTINGS_PATH" 2>/dev/null || echo 0)
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
SL_CFG="${PF_STATUSLINE_CONFIG:-$HOME/.config/pf-handoff/statusline.json}"
if [ -e "$SL_CFG" ]; then
  if [ -f "$SL_CFG" ] && python3 -m json.tool "$SL_CFG" > /dev/null 2>&1; then
    ok "status-bar config is valid ($SL_CFG)"
  else
    fail "status-bar config exists but does not parse as JSON — statusline silently falls back to defaults; check the syntax: python3 -m json.tool '$SL_CFG'"
  fi
else
  ok "status-bar config absent — default look (that is normal)"
fi

exit "$FAIL"
