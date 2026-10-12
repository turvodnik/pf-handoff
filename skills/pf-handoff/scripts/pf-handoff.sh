#!/usr/bin/env bash
# pf-handoff.sh — a helper for the agent on platforms without hooks (Antigravity,
# Grok, Codex) and for manual milestone handoffs. No model: it finds files and
# prints templates; the meaning is written by the agent (pf-handoff SKILL.md,
# «Milestone handoff»).
#
#   pf-handoff.sh --path  [--cwd DIR] [--slug SLUG]
#       Print the path of the project's active HANDOFF: the newest (by mtime)
#       <DIR>/.agents/runtime/handoff/*.md with `status: active` in its
#       frontmatter. None — create <date>-<slug>.md from the skill template
#       (status: active, updated: now) and print its path. Default slug: handoff.
#   pf-handoff.sh --short
#       Print the short milestone snapshot (5 fields, <= 15 lines) to fill in.
#   pf-handoff.sh --touch [--cwd DIR]
#       Set `updated:` in the active HANDOFF's frontmatter to the current time.
#
# The project is --cwd or the current directory — never $CLAUDE_PROJECT_DIR:
# the helper must answer for the directory it was run in.
# Exit codes: 0 ok; 1 nothing to touch / cannot create; 2 bad usage or no python3.
set -u

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; }

mode="" cwd="$PWD" slug="handoff"
while [ $# -gt 0 ]; do
  case "$1" in
    --path|--short|--touch) [ -z "$mode" ] || { echo "pf-handoff.sh: one mode only" >&2; exit 2; }; mode="${1#--}" ;;
    --cwd) [ $# -ge 2 ] || { echo "pf-handoff.sh: --cwd needs a value" >&2; exit 2; }; cwd="$2"; shift ;;
    --slug) [ $# -ge 2 ] || { echo "pf-handoff.sh: --slug needs a value" >&2; exit 2; }; slug="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "pf-handoff.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
[ -n "$mode" ] || { usage >&2; exit 2; }

if [ "$mode" = short ]; then
  # Field names stay Russian: this is an artifact template (HANDOFF), not a skill body.
  cat <<EOT
### Снимок $(date '+%Y-%m-%d %H:%M')
Цель: <зачем и критерий готовности, одной строкой>
Шаг: <что делаю сейчас и следующий проверяемый шаг>
Доказано: <факт — команда/тест/коммит; без доказательства сюда не писать>
Не делать: <отменённые направления — почему>
Запущено: <id субагента / PID / маркер council.sh — задание; «нет», если пусто>
EOT
  exit 0
fi

command -v python3 >/dev/null 2>&1 || { echo "pf-handoff.sh: python3 is required for --$mode" >&2; exit 2; }

case "$slug" in
  ''|*/*|.*) echo "pf-handoff.sh: bad --slug: '$slug'" >&2; exit 2 ;;
esac

TEMPLATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/references/handoff-template.md"

PFH_MODE="$mode" PFH_CWD="$cwd" PFH_SLUG="$slug" PFH_TEMPLATE="$TEMPLATE" python3 - <<'PY'
import os, re, sys, time

mode, cwd = os.environ["PFH_MODE"], os.environ["PFH_CWD"]
hdir = os.path.join(cwd, ".agents", "runtime", "handoff")
STATUS_ACTIVE = re.compile(r'^status:[ \t]*"?active"?([ \t]|$)')

def frontmatter(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = [l.rstrip("\n") for _, l in zip(range(200), fh)]
    except OSError:
        return None
    if not lines or lines[0].strip() != "---":
        return None
    for i, l in enumerate(lines[1:], 1):
        if l.strip() == "---":
            return lines[1:i]
    return None

def ensure_gitignore():
    # The HANDOFF directory ignores itself in git (QA 2.0.0, Y4) — a freshly
    # created one and an existing one without .gitignore alike (N3: every
    # project that ran v1.10.0 has the directory already). "x" never follows
    # a symlink sitting where .gitignore goes.
    try:
        with open(os.path.join(hdir, ".gitignore"), "x", encoding="utf-8") as fh:
            fh.write("*\n!.gitignore\n")
    except OSError:
        pass

def active():
    best = None
    try:
        names = os.listdir(hdir)
    except OSError:
        return None
    for n in names:
        p = os.path.join(hdir, n)
        if not n.endswith(".md") or not os.path.isfile(p):
            continue
        fm = frontmatter(p)
        if fm is None or not any(STATUS_ACTIVE.match(l) for l in fm):
            continue
        m = os.stat(p).st_mtime
        if best is None or m > best[0]:
            best = (m, p)
    return best[1] if best else None

now = time.strftime("%Y-%m-%d %H:%M")
cur = active()

if mode == "path":
    if cur:
        ensure_gitignore()
        print(cur); sys.exit(0)
    path = os.path.join(hdir, time.strftime("%Y-%m-%d") + "-" + os.environ["PFH_SLUG"] + ".md")
    if os.path.exists(path):
        print(f"pf-handoff.sh: {path} exists and is not active — set status: active or pass another --slug", file=sys.stderr)
        sys.exit(1)
    try:
        with open(os.environ["PFH_TEMPLATE"], encoding="utf-8") as fh:
            text = fh.read()
    except OSError as e:
        print(f"pf-handoff.sh: template not found: {e}", file=sys.stderr); sys.exit(1)
    text = re.sub(r"(?m)^updated:.*$", "updated: " + now, text, count=1)
    try:
        os.makedirs(hdir, exist_ok=True)
        ensure_gitignore()
        with open(path, "x", encoding="utf-8") as fh:
            fh.write(text)
    except OSError as e:
        print(f"pf-handoff.sh: cannot create {path}: {e}", file=sys.stderr); sys.exit(1)
    print(path); sys.exit(0)

# mode == touch
if not cur:
    print(f"pf-handoff.sh: no active HANDOFF in {hdir}", file=sys.stderr); sys.exit(1)
if os.path.islink(cur):
    print(f"pf-handoff.sh: {cur} is a symlink — refusing to write through it; edit the target by hand", file=sys.stderr)
    sys.exit(1)
ensure_gitignore()
with open(cur, encoding="utf-8") as fh:
    lines = fh.read().split("\n")
end = next((i for i, l in enumerate(lines[1:], 1) if l.strip() == "---"), None)
idx = next((i for i in range(1, end) if lines[i].startswith("updated:")), None)
if idx is None:
    lines.insert(end, "updated: " + now)
else:
    lines[idx] = "updated: " + now
# Atomic: a unique temp file (mkstemp) in the same directory, the original
# permissions copied onto it, then os.replace — an interrupted write never
# leaves an empty HANDOFF, and a 600 file stays 600.
import stat, tempfile
tmp = None
try:
    mode_bits = stat.S_IMODE(os.stat(cur).st_mode)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(cur), prefix=".pf-handoff-", suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
    os.chmod(tmp, mode_bits)
    os.replace(tmp, cur)
except OSError as e:
    if tmp:
        try:
            os.unlink(tmp)
        except OSError:
            pass
    print(f"pf-handoff.sh: cannot update {cur}: {e}", file=sys.stderr); sys.exit(1)
print(cur)
PY
