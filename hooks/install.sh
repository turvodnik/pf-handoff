#!/bin/bash
# Idempotent install of our hooks into Claude Code's settings.json, alongside
# any existing Orca entries (never touched — only read; we add our own).
#
# Unlike the four hook scripts, this is an operator tool (not invoked by
# Claude Code automatically), so errors are exit 1 with a message on stderr,
# not a silent exit 0.
#
# A registration of the same hook (or statusLine) that points at an EXISTING
# file outside this clone is someone else's wiring — another copy of these
# hooks, a canon checkout, a user's own status line. It is KEPT as is, with a
# `KEPT:` line; --force points everything at this clone (T-187).
set -u

FORCE=0
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    *) echo "install.sh: unknown flag: $a (valid: --force)" >&2; exit 2 ;;
  esac
done

SETTINGS_PATH="${CLAUDE_SETTINGS_PATH:-$HOME/.claude/settings.json}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# python3 is required by the installer (JSON validation, reading the existing
# registrations, the symlink target). Checked before the first write: without
# it the old code created/backed up settings.json and then reported a valid
# file as "invalid JSON" (QA 2.0.0, Y1). The hooks themselves run with jq OR
# python3 — only installing needs python3.
if ! command -v python3 >/dev/null 2>&1; then
  echo "install.sh: python3 is required to install the hooks (not found on PATH) — nothing was changed" >&2
  exit 1
fi

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
#
# The path goes inside single quotes, so a `'` in it (a clone under
# "Mike's tools") is written as '\'' — otherwise every hook command is a shell
# syntax error with rc=2, i.e. a blocked prompt and a blocked compaction
# (QA 2.0.0, R2). install.sh and doctor.sh read the escape back when they
# look for the registered path.
wrap() {
  local script
  script=$(printf '%s' "$1" | sed "s/'/'\\\\''/g")
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

# Which of our registrations belong to someone else (T-187): an entry for
# the same script name (or the statusLine) whose command names an existing
# file that is not this clone's script. Those events are left untouched.
# Pointing at this clone, or at a file that no longer exists -> upsert as
# before. A statusLine command with no file path at all (`npx ccusage
# statusline`, `ccstatusline`) is also someone's own choice -> kept (hooks
# keep the rule above). An existing file in ANOTHER pf-handoff clone
# (<dir>/hooks/<script>, <dir> holding install.sh and .claude-plugin/plugin.json
# named pf-handoff — or, in v1.10.0 and older, skills/pf-handoff/SKILL.md) is our own older copy, not someone else's: it is moved to
# this clone with a `MOVED:` line (QA 2.0.0, Y2) — otherwise a fresh clone
# left every hook on the old version. This machine's canon (context-hooks/, no
# plugin.json) stays KEPT. python3 is already required above. Output: line 1 —
# a JSON list of the kept events (for jq and the python merge), then one
# `KEPT:` or `MOVED:` line per event.
# A kept HOOK file with none of our scripts next to it (QA 2.0.0, N4) is
# another tool's hook that merely shares the file name (`precompact.sh`):
# kept all the same, but loudly — `WARN: KEPT:`, our hook for that event is
# not installed. With --force the scan still runs: every registration of an
# existing file elsewhere is named in a `REPLACED:` line before it is
# replaced (it used to go silently, a foreign hook included).
KEEP_JSON='[]'
KEEP_FILE="$(mktemp "${TMPDIR:-/tmp}/pfho-keep.XXXXXX")"
if ! PYTHONIOENCODING=utf-8 python3 - "$SETTINGS_PATH" "$SCRIPT_DIR" "$FORCE" > "$KEEP_FILE" 2>/dev/null <<'PYEOF'
import json, os, re, sys

path, here, force = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
with open(path, encoding="utf-8") as fh:
    d = json.load(fh)
INTERP = {"sh", "bash", "zsh", "dash", "env", "python", "python3", "node", "ruby", "perl"}
Q = chr(39)
ESC = Q + "\\" + Q + Q   # the escaped quote wrap() writes for a quote inside a path

def cmd_paths(cmd):
    # Words of a shell command that look like file paths: '…', "…" or bare;
    # only words that START like a path (/ ~ ./ ../ $VAR) count — not @scope/pkg, s/a/b/, https://…;
    # $HOME/… and ${HOME}/… are expanded below; interpreters (/bin/sh, /usr/bin/env …) are not it.
    # The escaped quote of wrap() is folded to \x01 first and restored in the word.
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
    # True when p is <dir>/hooks/<script> of another pf-handoff clone.
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
    # True when p sits next to our other hook scripts — a copy of these hooks
    # (this machine's canon context-hooks/, a hand copy), not another tool's
    # file that merely shares the name.
    d = os.path.dirname(os.path.realpath(p))
    return all(os.path.isfile(os.path.join(d, n)) for n in
               ("context-guard.sh", "precompact.sh", "sessionstart.sh", "autocheckpoint.sh"))

def foreign(cmd, name, ours):
    # The registered path when it is an existing file other than ours, else None.
    for p in cmd_paths(cmd):
        if name and os.path.basename(p) != name:
            continue
        if os.path.realpath(p) == os.path.realpath(ours):
            return None
        return p if os.path.isfile(p) else None
    return None

keep, msgs, moved, replaced, ours_cmds = [], [], [], [], {}
sl = d.get("statusLine")
if isinstance(sl, dict):
    scmd = (sl.get("command") or "").strip()
    p = foreign(scmd, None, os.path.join(here, "statusline.sh"))
    if force:
        if p or (scmd and not cmd_paths(scmd)):
            replaced.append(("statusLine", scmd, os.path.join(here, "statusline.sh")))
        p = None
    elif p and pfh_clone(p):
        moved.append(("statusLine", p, os.path.join(here, "statusline.sh"), scmd)); p = None
    elif not p and scmd and not cmd_paths(scmd):
        p = scmd   # no file path at all (npx ccusage statusline): someone's own choice
    if p:
        keep.append("statusLine"); msgs.append(("statusLine", p))
hooks = d.get("hooks") if isinstance(d.get("hooks"), dict) else {}
for evt, name in (("UserPromptSubmit", "context-guard.sh"), ("PostToolUse", "context-guard.sh"),
                  ("SessionStart", "sessionstart.sh"), ("PreCompact", "precompact.sh")):
    arr = hooks.get(evt)
    for item in arr if isinstance(arr, list) else []:
        for h in (item.get("hooks") or []) if isinstance(item, dict) else []:
            cmd = (h.get("command") or "") if isinstance(h, dict) else ""
            if "/" + name not in cmd:
                continue
            p = foreign(cmd, name, os.path.join(here, name))
            named = [x for x in cmd_paths(cmd) if os.path.basename(x) == name]
            if named and os.path.realpath(named[0]) == os.path.realpath(os.path.join(here, name)):
                ours_cmds.setdefault(evt, []).append(cmd)
            if force:
                if p:
                    replaced.append((evt, cmd, os.path.join(here, name)))
            elif p and pfh_clone(p):
                moved.append((evt, p, os.path.join(here, name), cmd))
            elif p and evt not in keep:
                keep.append(evt); msgs.append((evt, p))
# A kept event still gets OUR registration repointed (QA 2.0.0, N4, fix
# round 1): an older pf-handoff clone's command (and our own command in an
# older form) is replaced in place by this clone's command, the kept foreign
# hook next to it stays. Without this a foreign same-name hook pinned the
# event to the old clone's code, and doctor's advice looped.
repoint = {}
for e, p, n, c in moved:
    if e in keep:
        repoint.setdefault(e, []).append(c)
for e in keep:
    if e in repoint or e in ours_cmds:
        repoint.setdefault(e, []).extend(ours_cmds.get(e, []))
print(json.dumps(keep))
print("REPOINT_JSON " + json.dumps(repoint))
for e, p in msgs:
    if e != "statusLine" and not pfh_family(p) and e in repoint:
        print("WARN: KEPT: %s \u2192 %s is not a pf-handoff hook (same file name, none of our scripts next to it): "
              "kept next to ours. If that file is not yours to keep, re-run with --force (it is then REPLACED)" % (e, p))
    elif e != "statusLine" and not pfh_family(p):
        print("WARN: KEPT: %s \u2192 %s is not a pf-handoff hook (same file name, none of our scripts next to it): "
              "our %s hook is NOT installed. If that file is not yours to keep, re-run with --force "
              "(it is then REPLACED by ours)" % (e, p, e))
    else:
        print("KEPT: %s \u2192 %s (registered elsewhere; re-run with --force to point it at this clone)" % (e, p))
for e, c, n in replaced:
    print("REPLACED: %s %s \u2192 %s" % (e, c, n))
for e, p, n, c in moved:
    print("MOVED: %s %s \u2192 %s (an older pf-handoff clone)" % (e, p, n))
PYEOF
then
  rm -f "$KEEP_FILE"
  echo "install.sh: could not read the existing registrations in $SETTINGS_PATH, install aborted" >&2
  exit 1
fi
KEEP_JSON="$(head -1 "$KEEP_FILE")"
REPOINT_JSON="$(sed -n 's/^REPOINT_JSON //p' "$KEEP_FILE")"
[ -n "$REPOINT_JSON" ] || REPOINT_JSON='{}'
tail -n +2 "$KEEP_FILE" | grep -E '^(KEPT|MOVED|WARN: KEPT|REPLACED): ' || true
rm -f "$KEEP_FILE"

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
#
# Only OUR command object is replaced, in place (QA 2.0.0, R1): the group it
# sits in keeps its matcher and every foreign command next to ours — the old
# code replaced the whole group, silently dropping a neighbour hook and
# resetting a hand-narrowed matcher to "*". Our command in a second group (a
# duplicate from another clone) is removed; a group left empty goes too.
# {"matcher":"*"} is written only for a brand-new group.
def ours(marker): ((.command? // "") | tostring | contains(marker));
def put_ours(marker; hook):
  . as $hs
  | ([range(0; $hs | length) | select($hs[.] | ours(marker))] | first) as $k
  | [range(0; $hs | length) as $j | $hs[$j]
     | if $j == $k then hook elif ours(marker) then empty else . end];
def upsert(evt; marker; entry):
  ((.hooks[evt] // []) as $arr
   | ([$arr[]? | (.hooks // [])[] | select(ours(marker)) | .timeout] | first) // 10
  ) as $timeout
  | (entry.hooks[0] | .timeout = $timeout) as $hook
  | (.hooks[evt] // []) as $arr
  | ([range(0; $arr | length) | select(($arr[.].hooks // []) | any(ours(marker)))] | first) as $gi
  | if $gi == null then .hooks[evt] = $arr + [entry | .hooks = [$hook]]
    else .hooks[evt] = [range(0; $arr | length) as $i | $arr[$i]
      | if $i == $gi then .hooks = ((.hooks // []) | put_ours(marker; $hook))
        elif ((.hooks // []) | any(ours(marker))) then (.hooks = ((.hooks // []) | map(select(ours(marker) | not)))) | select((.hooks | length) > 0)
        else . end]
    end;

# A kept event (a foreign registration, T-187) is left as it is.
def unless_kept(evt; f): if ($keep | index(evt)) != null then . else f end;

unless_kept("statusLine"; .statusLine = {"type":"command","command":$sl_cmd})
| unless_kept("UserPromptSubmit"; upsert("UserPromptSubmit"; $cg_marker; {"matcher":"*","hooks":[{"type":"command","command":$cg_cmd,"timeout":10}]}))
| unless_kept("PostToolUse"; upsert("PostToolUse"; $cg_marker; {"matcher":"*","hooks":[{"type":"command","command":$cg_cmd,"timeout":10}]}))
| unless_kept("SessionStart"; upsert("SessionStart"; $ss_marker; {"hooks":[{"type":"command","command":$ss_cmd,"timeout":10}]}))
| unless_kept("PreCompact"; upsert("PreCompact"; $pc_marker; {"hooks":[{"type":"command","command":$pc_cmd,"timeout":10}]}))
'

merge_ok=1
if [ "$has_jq" = 1 ]; then
  if ! jq --argjson keep "$KEEP_JSON" --arg sl_cmd "$SL_CMD" --arg cg_cmd "$CG_CMD" --arg ss_cmd "$SS_CMD" --arg pc_cmd "$PC_CMD" \
         --arg cg_marker "/context-guard.sh" \
         --arg ss_marker "/sessionstart.sh" \
         --arg pc_marker "/precompact.sh" \
         "$JQ_FILTER" "$SETTINGS_PATH" > "$TMP_OUT" 2>/dev/null; then
    merge_ok=0
  fi
else
  if ! python3 - "$SETTINGS_PATH" "$SL_CMD" "$CG_CMD" "$SS_CMD" "$PC_CMD" "$KEEP_JSON" > "$TMP_OUT" 2>/dev/null <<'PYEOF'
import json, sys

path, sl_cmd, cg_cmd, ss_cmd, pc_cmd = sys.argv[1:6]
keep = set(json.loads(sys.argv[6]))   # events kept as someone else's (T-187)
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
            if ours(h, marker):
                return h["timeout"] if "timeout" in h else default
    return default

def ours(h, marker):
    return isinstance(h, dict) and marker in str(h.get("command") or "")

def upsert(d, evt, marker, entry):
    """Replace OUR command object with the current form; never touch a foreign one.

    Add-only left stale registrations in place forever (see the jq filter
    above): the `/bin/sh` wrapper that wedged Linux would have survived the
    documented `git pull && bash install.sh` update. Only our command is
    replaced, in place: the group's matcher and foreign neighbours stay
    (QA 2.0.0, R1); our duplicate in another group is removed.
    """
    arr = d.setdefault("hooks", {}).setdefault(evt, [])
    hook = entry["hooks"][0]
    gi = next((i for i, it in enumerate(arr)
               if isinstance(it, dict) and any(ours(h, marker) for h in it.get("hooks") or [])), None)
    if gi is None:
        arr.append(entry)
        return
    out = []
    for i, it in enumerate(arr):
        hs = (it.get("hooks") or []) if isinstance(it, dict) else []
        flags = [ours(h, marker) for h in hs]
        if i == gi:
            k = flags.index(True)
            it["hooks"] = [hook if j == k else h for j, h in enumerate(hs) if j == k or not flags[j]]
        elif any(flags):
            it["hooks"] = [h for j, h in enumerate(hs) if not flags[j]]
            if not it["hooks"]:
                continue
        out.append(it)
    arr[:] = out

# Markers match the file name, not the directory: the _tools canon keeps the
# scripts in context-hooks/, the public distribution — in hooks/. A directory-
# qualified marker broke idempotency and doctor for external users.
if "statusLine" not in keep:
    d["statusLine"] = {"type": "command", "command": sl_cmd}
for evt, marker, cmd, entry in (
        ("UserPromptSubmit", "/context-guard.sh", cg_cmd, {"matcher": "*"}),
        ("PostToolUse", "/context-guard.sh", cg_cmd, {"matcher": "*"}),
        ("SessionStart", "/sessionstart.sh", ss_cmd, {}),
        ("PreCompact", "/precompact.sh", pc_cmd, {})):
    if evt in keep:
        continue
    entry = dict(entry, hooks=[{"type": "command", "command": cmd,
                                "timeout": existing_timeout(d, evt, marker)}])
    upsert(d, evt, marker, entry)

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

# Kept events: our registration (an older clone's or our own older form) is
# repointed in place to this clone's command; duplicates of it are dropped,
# foreign neighbours stay (see REPOINT_JSON above).
if [ "$REPOINT_JSON" != '{}' ]; then
  if ! python3 - "$TMP_OUT" "$REPOINT_JSON" "$CG_CMD" "$SS_CMD" "$PC_CMD" > "$TMP_OUT.rp" 2>/dev/null <<'PYEOF'
import json, sys
path, rp, cg, ss, pc = sys.argv[1:6]
new = {"UserPromptSubmit": cg, "PostToolUse": cg, "SessionStart": ss, "PreCompact": pc}
d = json.load(open(path, encoding="utf-8"))
for evt, olds in json.loads(rp).items():
    mine = set(olds) | {new[evt]}
    placed, out = False, []
    for g in d.get("hooks", {}).get(evt, []):
        hs = []
        for h in (g.get("hooks") or []) if isinstance(g, dict) else []:
            if isinstance(h, dict) and h.get("command") in mine:
                if placed:
                    continue
                h = dict(h, command=new[evt]); placed = True
            hs.append(h)
        if isinstance(g, dict):
            if not hs and g.get("hooks"):
                continue
            g = dict(g, hooks=hs)
        out.append(g)
    d["hooks"][evt] = out
print(json.dumps(d, indent=2, ensure_ascii=False))
PYEOF
  then
    echo "install.sh: could not repoint our registration in a kept event, no changes applied" >&2
    rm -f "$TMP_OUT" "$TMP_OUT.rp"
    exit 1
  fi
  mv "$TMP_OUT.rp" "$TMP_OUT"
fi

mv "$TMP_OUT" "$SETTINGS_PATH"

AFTER_ORCA_COUNT=$(grep -c 'orca/agent-hooks' "$SETTINGS_PATH" 2>/dev/null); AFTER_ORCA_COUNT=${AFTER_ORCA_COUNT:-0}

echo "install.sh: done. $SETTINGS_PATH updated (jq=$has_jq)."
echo "install.sh: grep -c 'orca/agent-hooks': before=$BEFORE_ORCA_COUNT, after=$AFTER_ORCA_COUNT"
exit 0
