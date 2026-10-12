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
warn() { printf 'WARN %s\n' "$1"; }
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
# Each registration names a script path. This clone's script -> OK; an
# EXISTING file elsewhere (canon checkout, another copy, a user's own status
# line) -> OK as KEPT, with the path: install.sh leaves such wiring alone
# (T-187); a statusLine command with no file path (npx ccusage statusline)
# is KEPT too and the command is named; a missing file or no registration -> FAIL. A file in
# ANOTHER pf-handoff clone (install.sh + .claude-plugin/plugin.json named
# pf-handoff, or skills/pf-handoff/SKILL.md in v1.10.0 and older) -> WARN, not FAIL: the hooks run, but an older copy of them
# (QA 2.0.0, Y2); install.sh from this clone moves it here. A kept HOOK file
# with none of our scripts next to it is another tool's file of the same name
# -> WARN: our hook for that event is not installed (QA 2.0.0, N4). Without python3 the
# old file-name check stands in (any "/<name>.sh" counts).
if command -v python3 >/dev/null 2>&1; then
  REG_OUT="$(PYTHONIOENCODING=utf-8 python3 - "$SETTINGS_PATH" "$SCRIPT_DIR" 2>/dev/null <<'PYEOF'
import json, os, re, sys

path, here = sys.argv[1:3]
try:
    with open(path, encoding="utf-8-sig") as fh:
        d = json.load(fh)
except Exception:
    d = {}
if not isinstance(d, dict):
    d = {}
INTERP = {"sh", "bash", "zsh", "dash", "env", "python", "python3", "node", "ruby", "perl"}
Q = chr(39)
ESC = Q + "\\" + Q + Q   # the escaped quote install.sh writes for a quote inside a path

def cmd_paths(cmd):
    # Same reading as install.sh: only words starting with / ~ ./ ../ $VAR are paths (not @scope/pkg, s/a/b/).
    out = []
    for a, b, c in re.findall(r"'([^']*)'|\"([^\"]*)\"|([^\s;'\"]+)", (cmd or "").replace(ESC, "\x01")):
        t = (a or b or c).replace("\x01", Q)
        if not re.match(r"^(/|~|\.{1,2}/|\$[A-Za-z_{])", t) or t.startswith("/dev/"):
            continue
        t = os.path.expanduser(os.path.expandvars(t))
        if os.path.basename(t) in INTERP:
            continue
        out.append(t)
    return out

def pfh_clone(p):
    # Same test as install.sh: p is <dir>/hooks/<script> of a pf-handoff clone.
    hooks_dir = os.path.dirname(os.path.realpath(p))
    root = os.path.dirname(hooks_dir)
    if os.path.basename(hooks_dir) != "hooks" or not os.path.isfile(os.path.join(root, "install.sh")):
        return False
    try:
        with open(os.path.join(root, ".claude-plugin", "plugin.json"), encoding="utf-8") as fh:
            if json.load(fh).get("name") == "pf-handoff":
                return True
    except Exception:
        pass
    # v1.10.0 and older clones carry no plugin.json: the shipped skill names us.
    try:
        with open(os.path.join(root, "skills", "pf-handoff", "SKILL.md"), encoding="utf-8") as fh:
            return any(l.strip() == "name: pf-handoff" for _, l in zip(range(10), fh))
    except Exception:
        return False

def pfh_family(p):
    # Same test as install.sh: p sits next to our other hook scripts.
    d = os.path.dirname(os.path.realpath(p))
    return all(os.path.isfile(os.path.join(d, n)) for n in
               ("context-guard.sh", "precompact.sh", "sessionstart.sh", "autocheckpoint.sh"))

def verdict(label, cmds, name):
    # Every matching registration counts, not the first one: ours anywhere
    # -> OK; else an existing foreign file -> KEPT; else a missing file.
    ours = os.path.realpath(os.path.join(here, name))
    found = []
    for cmd in cmds:
        for p in cmd_paths(cmd):
            if name != "statusline.sh" and os.path.basename(p) != name:
                continue
            found.append(p)
            break
    if any(os.path.realpath(p) == ours for p in found):
        return "OK\t%s points at our %s" % (label, name)
    for p in found:
        if os.path.isfile(p) and pfh_clone(p):
            return "WARN\t%s points at another pf-handoff clone: %s (bash install.sh from this clone moves it here)" % (label, p)
    for p in found:
        if os.path.isfile(p):
            if label != "statusLine" and not pfh_family(p):
                return ("WARN\tKEPT: %s \u2192 %s is not a pf-handoff hook (same file name, none of our scripts next to it): "
                        "our %s hook is NOT installed; bash install.sh --force replaces it" % (label, p, label))
            return "OK\tKEPT: %s \u2192 %s (registered elsewhere; bash install.sh --force points it at this clone)" % (label, p)
    if found:
        return "FAIL\t%s points at a missing file: %s" % (label, found[0])
    if label == "statusLine":
        # A command with no file path at all (npx ccusage statusline): the
        # own status line of the user, kept by install.sh -> OK, name the command.
        for cmd in cmds:
            if cmd.strip():
                return "OK\tKEPT: %s \u2192 %s (registered elsewhere; bash install.sh --force points it at this clone)" % (label, cmd.strip())
    return "FAIL\t%s: %s not registered" % (label, name)

def hook_cmds(evt, name):
    arr = (d.get("hooks") or {}).get(evt) if isinstance(d.get("hooks"), dict) else None
    out = []
    for item in arr if isinstance(arr, list) else []:
        for h in (item.get("hooks") or []) if isinstance(item, dict) else []:
            cmd = (h.get("command") or "") if isinstance(h, dict) else ""
            if "/" + name in cmd:
                out.append(cmd)
    return out

sl = d.get("statusLine")
print(verdict("statusLine", [sl.get("command") or ""] if isinstance(sl, dict) else [], "statusline.sh"))
for evt, name in (("UserPromptSubmit", "context-guard.sh"), ("PostToolUse", "context-guard.sh"),
                  ("SessionStart", "sessionstart.sh"), ("PreCompact", "precompact.sh")):
    print(verdict(evt, hook_cmds(evt, name), name))
PYEOF
)"
  if [ -z "$REG_OUT" ]; then
    fail "could not read the registrations in $SETTINGS_PATH"
  fi
  while IFS="$(printf '\t')" read -r verdict msg; do
    [ -n "$verdict" ] || continue
    case "$verdict" in
      OK) ok "$msg" ;;
      WARN) warn "$msg" ;;
      *) fail "$msg" ;;
    esac
  done <<EOF
$REG_OUT
EOF
else
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
