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
#
# The interpreter is named EXPLICITLY (`bash`), and that is the whole point of
# this line. Claude Code runs the command through the system shell, so a bare
# `/bin/sh '<script>'` ignores the `#!/bin/bash` shebang: on macOS /bin/sh IS
# bash in POSIX mode and everything works, but on Debian/Ubuntu /bin/sh is dash,
# which does not understand the bash-isms our hooks use (`<<<`, $'\x1f') — every
# hook died with a syntax error and rc=2, and rc=2 is not "did nothing": for
# PreCompact it means "compaction blocked" and for UserPromptSubmit "prompt
# blocked and erased". So on Linux the gate wedged EVERY compaction.
#
# Why explicit bash rather than making the hooks POSIX: the hooks are ~1500
# lines of bash that would have to be rewritten and re-proved (arrays, local,
# <<<, $'…'), and every future edit would have to stay POSIX with no test able
# to notice on macOS. Naming the interpreter is one word and cannot regress.
#
# `bash` via PATH, not /bin/bash: on NixOS/Homebrew-only machines bash is not in
# /bin. No bash at all -> the else branch drains stdin and exits 0 — the hook
# self-disables instead of wedging the session (a hook that cannot run must not
# block; blocking is only for "the snapshot was not written").
wrap() {
  local script="$1"
  printf "if [ -f '%s' ] && [ -r '%s' ] && [ -x '%s' ] && command -v bash >/dev/null 2>&1; then bash '%s'; else { command -p cat 2>/dev/null || cat; } >/dev/null 2>&1 || :; fi" \
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

# upsert, not add-if-missing: OUR entry (matched by the script file name) is
# replaced with the current form, a foreign one is never touched. Add-only was
# a trap — a machine that already had the old `/bin/sh` wrapper kept it forever,
# because "an entry mentioning precompact.sh exists" looked like "installed".
# `git pull && bash install.sh`, the documented update path, then repaired
# nothing. Idempotency is unchanged: the replacement is byte-identical on the
# second run.
JQ_FILTER='
# Preserve a manually-raised timeout across reinstalls: if OUR entry already
# exists (matched by marker), reuse its current timeout instead of always
# writing 10. Only a brand-new registration gets the 10 default. Without this,
# every `git pull && bash install.sh` silently rolled back a timeout someone
# had increased by hand (e.g. because their machine needs longer than 10s to
# write the PreCompact snapshot) — a silent revert of a manual setting.
def upsert(evt; marker; entry):
  ((.hooks[evt] // []) as $arr
   | ([$arr[]? | (.hooks // [])[] | select((.command? // "") | contains(marker)) | .timeout] | first) // 10
  ) as $timeout
  | (entry | .hooks[0].timeout = $timeout) as $final
  | .hooks[evt] = ((.hooks[evt] // []) as $arr
    | if ($arr | any(.hooks[]?.command? // "" | contains(marker)))
      then ($arr | map(if ((.hooks // []) | any(.command? // "" | contains(marker))) then $final else . end))
      else $arr + [$final]
      end);

.statusLine = {"type":"command","command":$sl_cmd}
| upsert("UserPromptSubmit"; $cg_marker; {"matcher":"*","hooks":[{"type":"command","command":$cg_cmd,"timeout":10}]})
| upsert("PostToolUse"; $cg_marker; {"matcher":"*","hooks":[{"type":"command","command":$cg_cmd,"timeout":10}]})
| upsert("SessionStart"; $ss_marker; {"hooks":[{"type":"command","command":$ss_cmd,"timeout":10}]})
| upsert("PreCompact"; $pc_marker; {"hooks":[{"type":"command","command":$pc_cmd,"timeout":10}]})
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

def existing_timeout(d, evt, marker, default=10):
    """Timeout of OUR entry for this event, if one is already installed.

    Mirrors the jq twin: reinstalling must not roll back a timeout someone
    raised by hand (e.g. because their machine needs longer than 10s to write
    the PreCompact snapshot) back down to the 10 default.
    """
    for item in d.get("hooks", {}).get(evt, []):
        for h in item.get("hooks", []):
            if marker in (h.get("command") or "") and "timeout" in h:
                return h["timeout"]
    return default

def upsert(d, evt, marker, entry):
    """Replace OUR entry with the current form; never touch a foreign one.

    Add-only left stale registrations in place forever (see the jq filter
    above): the `/bin/sh` wrapper that wedged Linux would have survived the
    documented `git pull && bash install.sh` update.
    """
    arr = d.setdefault("hooks", {}).setdefault(evt, [])
    replaced = False
    for i, item in enumerate(arr):
        for h in item.get("hooks", []):
            if marker in (h.get("command") or ""):
                arr[i] = entry
                replaced = True
                break
    if not replaced:
        arr.append(entry)

# Markers match the file name, not the directory: the _tools canon keeps the
# scripts in context-hooks/, the public distribution — in hooks/. A directory-
# qualified marker broke idempotency and doctor for external users.
d["statusLine"] = {"type": "command", "command": sl_cmd}
upsert(d, "UserPromptSubmit", "/context-guard.sh",
    {"matcher": "*", "hooks": [{"type": "command", "command": cg_cmd,
     "timeout": existing_timeout(d, "UserPromptSubmit", "/context-guard.sh")}]})
upsert(d, "PostToolUse", "/context-guard.sh",
    {"matcher": "*", "hooks": [{"type": "command", "command": cg_cmd,
     "timeout": existing_timeout(d, "PostToolUse", "/context-guard.sh")}]})
upsert(d, "SessionStart", "/sessionstart.sh",
    {"hooks": [{"type": "command", "command": ss_cmd,
     "timeout": existing_timeout(d, "SessionStart", "/sessionstart.sh")}]})
upsert(d, "PreCompact", "/precompact.sh",
    {"hooks": [{"type": "command", "command": pc_cmd,
     "timeout": existing_timeout(d, "PreCompact", "/precompact.sh")}]})

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
