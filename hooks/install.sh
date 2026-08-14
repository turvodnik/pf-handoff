#!/bin/bash
# Idempotent install of our hooks into Claude Code's settings.json, alongside
# any existing Orca entries (never touched — only read; we add our own).
#
# Unlike the four hook scripts, this is an operator tool (not invoked by
# Claude Code automatically), so errors are exit 1 with a message on stderr,
# not a silent exit 0.
set -u

SETTINGS_PATH="${CLAUDE_SETTINGS_PATH:-$HOME/.claude/settings.json}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# settings.json may be a symlink (dotfiles repos): work with its target,
# otherwise mv would replace the symlink with a plain file, leaving the target stale.
if [ -L "$SETTINGS_PATH" ]; then
  SETTINGS_PATH="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$SETTINGS_PATH")"
  echo "install.sh: settings.json is a symlink, working with its target: $SETTINGS_PATH"
fi

STATUSLINE_SH="$SCRIPT_DIR/statusline.sh"
CONTEXT_GUARD_SH="$SCRIPT_DIR/context-guard.sh"
SESSIONSTART_SH="$SCRIPT_DIR/sessionstart.sh"
PRECOMPACT_SH="$SCRIPT_DIR/precompact.sh"
# Not registered in settings.json — precompact.sh and context-guard.sh call it
# next to themselves. Checked here all the same: if it is missing, PreCompact
# treats "no checkpoint" as a reason to BLOCK compaction (T-031), so an install
# without this file would quietly turn into a wedged session later.
AUTOCHECKPOINT_SH="$SCRIPT_DIR/autocheckpoint.sh"

for f in "$STATUSLINE_SH" "$CONTEXT_GUARD_SH" "$SESSIONSTART_SH" "$PRECOMPACT_SH" "$AUTOCHECKPOINT_SH"; do
  if [ ! -x "$f" ]; then
    echo "install.sh: expected script missing or not executable: $f" >&2
    exit 1
  fi
done

if [ ! -f "$SETTINGS_PATH" ]; then
  # Fresh machine: Claude Code has not created settings.json yet — create a
  # minimal one and continue (an out-of-the-box install is impossible otherwise).
  mkdir -p "$(dirname "$SETTINGS_PATH")"
  printf '{}\n' > "$SETTINGS_PATH"
  echo "install.sh: settings.json not found — created a new empty one: $SETTINGS_PATH"
fi

if ! python3 -m json.tool "$SETTINGS_PATH" > /dev/null 2>&1; then
  echo "install.sh: original $SETTINGS_PATH is invalid JSON, install aborted" >&2
  exit 1
fi

# Guard wrapper "after the Orca pattern": exists/readable/executable — otherwise
# silently drain stdin (same structure already used in settings.json).
wrap() {
  local script="$1"
  printf "if [ -f '%s' ] && [ -r '%s' ] && [ -x '%s' ]; then /bin/sh '%s'; else { command -p cat 2>/dev/null || cat; } >/dev/null 2>&1 || :; fi" \
    "$script" "$script" "$script" "$script"
}

SL_CMD="$(wrap "$STATUSLINE_SH")"
CG_CMD="$(wrap "$CONTEXT_GUARD_SH")"
SS_CMD="$(wrap "$SESSIONSTART_SH")"
PC_CMD="$(wrap "$PRECOMPACT_SH")"

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_PATH="${SETTINGS_PATH}.bak-${TS}"
cp "$SETTINGS_PATH" "$BACKUP_PATH"
echo "install.sh: backup created: $BACKUP_PATH"

BEFORE_ORCA_COUNT=$(grep -c 'orca/agent-hooks' "$SETTINGS_PATH" 2>/dev/null); BEFORE_ORCA_COUNT=${BEFORE_ORCA_COUNT:-0}

has_jq=0
command -v jq >/dev/null 2>&1 && has_jq=1

TMP_OUT="$(mktemp "${SETTINGS_PATH}.XXXXXX")"

JQ_FILTER='
def add_if_missing(evt; marker; entry):
  .hooks[evt] = ((.hooks[evt] // []) as $arr
    | if ($arr | any(.hooks[]?.command? // "" | contains(marker))) then $arr
      else $arr + [entry]
      end);

.statusLine = {"type":"command","command":$sl_cmd}
| add_if_missing("UserPromptSubmit"; $cg_marker; {"matcher":"*","hooks":[{"type":"command","command":$cg_cmd,"timeout":10}]})
| add_if_missing("PostToolUse"; $cg_marker; {"matcher":"*","hooks":[{"type":"command","command":$cg_cmd,"timeout":10}]})
| add_if_missing("SessionStart"; $ss_marker; {"hooks":[{"type":"command","command":$ss_cmd,"timeout":10}]})
| add_if_missing("PreCompact"; $pc_marker; {"hooks":[{"type":"command","command":$pc_cmd,"timeout":10}]})
'

merge_ok=1
if [ "$has_jq" = 1 ]; then
  if ! jq --arg sl_cmd "$SL_CMD" --arg cg_cmd "$CG_CMD" --arg ss_cmd "$SS_CMD" --arg pc_cmd "$PC_CMD" \
         --arg cg_marker "/context-guard.sh" \
         --arg ss_marker "/sessionstart.sh" \
         --arg pc_marker "/precompact.sh" \
         "$JQ_FILTER" "$SETTINGS_PATH" > "$TMP_OUT" 2>/dev/null; then
    merge_ok=0
  fi
else
  if ! python3 - "$SETTINGS_PATH" "$SL_CMD" "$CG_CMD" "$SS_CMD" "$PC_CMD" > "$TMP_OUT" 2>/dev/null <<'PYEOF'
import json, sys

path, sl_cmd, cg_cmd, ss_cmd, pc_cmd = sys.argv[1:6]
with open(path, encoding="utf-8") as fh:
    d = json.load(fh)

def add_if_missing(d, evt, marker, entry):
    arr = d.setdefault("hooks", {}).setdefault(evt, [])
    for item in arr:
        for h in item.get("hooks", []):
            if marker in (h.get("command") or ""):
                return
    arr.append(entry)

# Markers match the file name, not the directory: the _tools canon keeps the
# scripts in context-hooks/, the public distribution — in hooks/. A directory-
# qualified marker broke idempotency and doctor for external users.
d["statusLine"] = {"type": "command", "command": sl_cmd}
add_if_missing(d, "UserPromptSubmit", "/context-guard.sh",
    {"matcher": "*", "hooks": [{"type": "command", "command": cg_cmd, "timeout": 10}]})
add_if_missing(d, "PostToolUse", "/context-guard.sh",
    {"matcher": "*", "hooks": [{"type": "command", "command": cg_cmd, "timeout": 10}]})
add_if_missing(d, "SessionStart", "/sessionstart.sh",
    {"hooks": [{"type": "command", "command": ss_cmd, "timeout": 10}]})
add_if_missing(d, "PreCompact", "/precompact.sh",
    {"hooks": [{"type": "command", "command": pc_cmd, "timeout": 10}]})

print(json.dumps(d, indent=2, ensure_ascii=False))
PYEOF
  then
    merge_ok=0
  fi
fi

if [ "$merge_ok" != 1 ] || [ ! -s "$TMP_OUT" ]; then
  echo "install.sh: JSON merge failed, no changes applied" >&2
  rm -f "$TMP_OUT"
  exit 1
fi

if ! python3 -m json.tool "$TMP_OUT" > /dev/null 2>&1; then
  echo "install.sh: merge produced invalid JSON, restoring the backup" >&2
  cp "$BACKUP_PATH" "$SETTINGS_PATH"
  rm -f "$TMP_OUT"
  exit 1
fi

mv "$TMP_OUT" "$SETTINGS_PATH"

AFTER_ORCA_COUNT=$(grep -c 'orca/agent-hooks' "$SETTINGS_PATH" 2>/dev/null); AFTER_ORCA_COUNT=${AFTER_ORCA_COUNT:-0}

echo "install.sh: done. $SETTINGS_PATH updated (jq=$has_jq)."
echo "install.sh: grep -c 'orca/agent-hooks': before=$BEFORE_ORCA_COUNT, after=$AFTER_ORCA_COUNT"
exit 0
