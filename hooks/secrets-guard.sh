#!/bin/bash
# PreToolUse guard on Bash (T-082): refuses the CLOSED list of wide commands
# over secrets from AGENTS.md §5 — the rule existed only as prose, and the
# invariant was broken 3x in two days (key values landing in session context).
#
# Contract (Claude Code hooks): the event JSON arrives on stdin; exit 2 blocks
# the tool call and the stderr text is shown to the agent as the reason; any
# other exit code lets the call through.
#
# This hook runs on EVERY Bash call of EVERY session on the machine, so two
# properties outrank everything else:
#
#  1. FAIL-OPEN. Anything unexpected — no python3, unparseable JSON, an
#     exception inside the analyzer — is exit 0 plus a VISIBLE note on stderr.
#     A typo here must never wedge every session; and it must not degrade
#     silently either (§11). Exit 2 is reachable ONLY from an explicit rule hit.
#  2. A CLOSED list. No "looks like a secret" heuristics: a false block costs
#     more than a miss (SPEC-workflow-upgrade.md, risk «Ложная блокировка
#     хуком»). `set` is deliberately NOT on the list even though §5's prose
#     names it — every script here opens with `set -uo pipefail`.
#
# Why one embedded Python program instead of the jq-first/python-fallback shape
# of context-guard.sh: the analyzer has to be heredoc- and comment-aware and
# must judge only COMMAND POSITIONS (`grep printenv file` is not a dump). That
# is unreadable in jq, and two implementations would be two things to test.
# Why embedded rather than a sibling .py: pf-handoff's sync-from-tools.sh copies
# `context-hooks/*.sh` only, so a .py neighbour would not ship with the hook.
#
# Comments in English (this file is copied into the public pf-handoff
# distribution, §2); the reason shown to the agent stays Russian, like the
# THRESH_* strings of context-guard.sh next door.
# ---------------------------------------------------------------------------
# MOVED TO pf-guard (T-115). The canonical hook is now
# `pf-guard/hooks/secrets-guard.sh` (github.com/turvodnik/pf-guard); the body
# below is kept as a FALLBACK so that a machine without pf-guard loses nothing.
# Resolution order: PF_GUARD_HOME, when set, is the ONLY place looked at (so a
# test can prove the fallback with PF_GUARD_HOME=/nonexistent); otherwise the
# two layouts this file ships in are tried — `<root>/context-hooks/` next to
# `<root>/repos/pf-guard` (the origin workshop) and `repos/pf-handoff/hooks/`
# next to `repos/pf-guard/hooks/` (the distribution clone). The target must be
# a different, readable file (`-ef` guards against exec'ing ourselves). Until
# the next pf-handoff release registers nothing here, both copies stay
# byte-identical (sync-from-tools.sh copies this file verbatim).
set -u
PF_SG_SELF="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)/$(basename "${BASH_SOURCE[0]:-$0}")"
PF_SG_DIR="$(dirname "$PF_SG_SELF")"
# A plain loop over positional arguments (paths may contain spaces): no heredoc
# here on purpose — `exec` inside a `while … done <<EOF` inherits the heredoc
# as stdin and the target hook would never see the event JSON.
pf_sg_redirect() {
  for pf_sg_target in "$@"; do
    if [ -s "$pf_sg_target" ] && [ -r "$pf_sg_target" ] && ! [ "$pf_sg_target" -ef "$PF_SG_SELF" ]; then
      exec bash "$pf_sg_target"
    fi
  done
}
if [ -n "${PF_GUARD_HOME:-}" ]; then
  pf_sg_redirect "$PF_GUARD_HOME/hooks/secrets-guard.sh"
else
  pf_sg_redirect "$PF_SG_DIR/../repos/pf-guard/hooks/secrets-guard.sh" \
                 "$PF_SG_DIR/../../pf-guard/hooks/secrets-guard.sh"
fi
unset -f pf_sg_redirect
unset PF_SG_SELF PF_SG_DIR pf_sg_target
# --- fallback: the original hook body, unchanged ---------------------------

# Fail-open note: JSON with `systemMessage` on stdout is the documented visible
# channel for a hook that exits 0; stderr is kept for a human reading a log.
# The messages are fixed strings without quotes, so no JSON escaping is needed.
note() {
  printf '{"systemMessage": "secrets-guard: %s — страж §5 ПРОПУСКАЕТ этот вызов (fail-open)."}\n' "$1"
  printf 'secrets-guard: %s — страж §5 ПРОПУСКАЕТ этот вызов (fail-open).\n' "$1" >&2
}

# `command -p cat` (the wrapper pattern already used in install.sh and by
# Orca): with a broken PATH a bare `cat` is not found, and the hook exited 1
# with no note of its own instead of stepping aside cleanly.
input=$({ command -p cat 2>/dev/null || cat; })

# No raw-byte fast path here (review round 2): a substring test for `Bash`
# BEFORE parsing let unparseable input without that word exit 0 in complete
# silence, against the fail-open contract above. Silence is allowed only for
# VALID JSON whose tool_name is not Bash — and that decision needs the parser.
# Price: a non-Bash event now costs the python3 start (~30 ms) instead of ~6.

if ! command -v python3 >/dev/null 2>&1; then
  note "python3 не найден"
  exit 0
fi

IFS='' read -r -d '' PF_SG_PY <<'SGUARD_PY' || :
import json
import os
import re
import sys
from fnmatch import fnmatch

ALLOW, BLOCK = 0, 2

READERS = ("cat", "less", "more", "head", "tail", "bat")
FILTERS = ("grep", "rg", "egrep", "fgrep")
SHELLS = ("bash", "sh", "zsh", "dash", "ksh")
# Patterns are matched against a LOWERCASED basename: macOS filesystems are
# case-insensitive by default, so 'cat .ENV' opens the same file as 'cat .env'.
SECRET_GLOBS = ("*.env", ".env.*", "*id_rsa*", "*.pem", "*credentials*.json")
# Allow-side exception. `.env.example` is required by the ticket; the three
# neighbours are the same class of committed placeholder file. Widening the
# ALLOW list can only cause a miss, never a false block.
# `.pub` is the PUBLIC half of a key pair — not a secret (review round 1).
PLACEHOLDER_SUFFIXES = (".example", ".sample", ".template", ".dist", ".pub")
WP_SECRET_WORDS = ("key", "secret", "token", "password")

# Words that stand BEFORE the real command word.
PREFIX_SKIP = (
    "sudo", "command", "builtin", "exec", "nohup", "nice", "time",
    "if", "then", "else", "elif", "while", "until", "do", "!",
    "{", "}", "[", "[[", "(", ")",
)
# Flags of those wrappers that consume the NEXT token, so that the token is not
# mistaken for the command word (`sudo -u root cat …` must still reach `cat`).
PREFIX_VALUE_FLAGS = ("-u", "-g", "-U", "-C", "-n", "-r", "-t", "--user", "--group")

ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
# `.` and `-` belong in the tag class: `<<'END-OF-FILE'` is a legal heredoc.
# Digits still cannot start a tag, so `$(( a << 2 ))` is untouched.
HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_.-]*)\1")
REDIRECT = re.compile(r"^[0-9]*(<<-?|<|>>|>|&>>|&>|>&|<&)(-|[0-9]+)?$")
REDIRECT_SELF = re.compile(r"^[0-9]*(>&|<&)(-|[0-9]+)$")   # `2>&1`: target embedded
WRITE_REDIRECT = re.compile(r"^[0-9]*(>>|>|&>>|&>)$")
MAX_DEPTH = 6

FIX = ("Значение секрета получают только так: `ai-secret run <scope> -- <команда>` "
       "(правила — AGENTS.md §5).")


def note(msg):
    """Visible fail-open note. stderr on exit 0 is not a documented channel for
    Claude Code hooks; the documented one is a JSON object on stdout with
    `systemMessage` (hooks reference, "Hook JSON Output"). Both are written."""
    text = "secrets-guard: %s — страж §5 ПРОПУСКАЕТ этот вызов (fail-open)." % msg
    sys.stdout.write(json.dumps({"systemMessage": text}, ensure_ascii=False) + "\n")
    sys.stderr.write(text + "\n")


def one_line(value):
    """The reason must be ONE line — an argument may carry newlines itself."""
    text = re.sub(r"\s+", " ", str(value)).strip()
    return text[:160] + ("…" if len(text) > 160 else "")


def strip_heredocs(text):
    """Split off heredoc bodies: they are data, not commands.

    Returns (text without the bodies, bodies whose tag was UNQUOTED). Two traps
    are handled here, both found by review:

    * A body is removed ONLY when its terminator actually appears. A `<<EOF`
      sitting inside a quoted string is not a heredoc, and swallowing the rest
      of the command on its word hid real commands from the analyzer.
    * With an UNQUOTED tag bash still expands `$(…)` inside the body, so those
      bodies are handed back for command-substitution scanning instead of being
      dropped. With a quoted tag the body is literal and is dropped outright.
    """
    lines = text.split("\n")
    out, expanded = [], []
    i, n = 0, len(lines)
    while i < n:
        out.append(lines[i])
        tags = [(m.group(1), m.group(2)) for m in HEREDOC.finditer(lines[i])]
        i += 1
        for quoted, tag in tags:
            j = i
            while j < n and lines[j].strip() != tag:
                j += 1
            if j >= n:
                break                      # no terminator -> it was not a heredoc
            if not quoted:
                expanded.extend(lines[i:j])
            i = j + 1
    return "\n".join(out), "\n".join(expanded)


def substitutions(text):
    """Every `$(…)` and backtick body, at any nesting, outside single quotes.

    Inside DOUBLE quotes bash still runs a substitution, so 'echo "$(printenv)"'
    is a command position even though the tokenizer sees one quoted token.
    Inside single quotes nothing expands, so those are skipped.
    """
    found = []
    i, n, quote = 0, len(text), None
    while i < n:
        ch = text[i]
        if quote == "'":
            quote = None if ch == "'" else quote
            i += 1
            continue
        if quote == '"':
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                quote = None
                i += 1
                continue
        elif ch in ("'", '"'):
            quote = ch
            i += 1
            continue
        elif ch == "#" and (i == 0 or text[i - 1] in " \t\n;|&()`"):
            nl = text.find("\n", i)            # a comment is not a command
            i = n if nl < 0 else nl
            continue
        if text[i:i + 2] == "$(" or ch == "`":
            closer, start = (")", i + 2) if ch == "$" else ("`", i + 1)
            depth, j = 1, start
            while j < n and depth:
                if closer == ")" and text[j:j + 2] == "$(":
                    depth += 1
                    j += 2
                    continue
                if text[j] == closer:
                    depth -= 1
                    if not depth:
                        break
                j += 1
            if j < n:
                inner = text[start:j]
                found.append(inner)
                found.extend(substitutions(inner))
                i = j + 1
                continue
        i += 1
    return found


def split_segments(text):
    """Command-position segments plus the separator that follows each one.

    Separators are the unquoted `; | & && || newline ( ) $( backtick`.
    Redirections are emitted as their own tokens so that 'printenv>/tmp/out'
    does not collapse into one unrecognisable word.
    """
    segs, cur, buf, sep = [], [], "", ""
    quote = None
    i, n = 0, len(text)

    def flush_token():
        nonlocal buf
        if buf:
            cur.append(buf)
            buf = ""

    def flush_segment(separator):
        nonlocal cur
        flush_token()
        if cur:
            segs.append((cur, separator))
        cur = []

    while i < n:
        ch = text[i]
        if quote == "'":
            if ch == "'":
                quote = None
            else:
                buf += ch
            i += 1
            continue
        if quote == '"':
            if ch == "\\" and i + 1 < n:
                buf += text[i + 1]
                i += 2
                continue
            if ch == '"':
                quote = None
            else:
                buf += ch
            i += 1
            continue
        if ch in ("'", '"'):
            quote = ch
            i += 1
            continue
        if ch == "\\" and i + 1 < n:
            buf += text[i + 1]
            i += 2
            continue
        if ch == "#" and not buf and (i == 0 or text[i - 1] in " \t\n;|&()`"):
            nl = text.find("\n", i)
            i = n if nl < 0 else nl
            continue
        if ch in " \t":
            flush_token()
            i += 1
            continue
        if ch in "<>":
            # An all-digit word glued to the operator is the fd prefix
            # (`2>&1`, `2>/dev/null`), not an argument of the command.
            run = ""
            if buf and buf.isdigit():
                run, buf = buf, ""
            flush_token()
            while i < n and text[i] in "<>":
                run += text[i]
                i += 1
            if i < n and text[i] == "&":            # `>&1`, `<&0`, `>&-`
                run += "&"
                i += 1
                while i < n and (text[i].isdigit() or text[i] == "-"):
                    run += text[i]
                    i += 1
            cur.append(run)
            continue
        two = text[i:i + 2]
        if two in ("&&", "||", ";;"):
            flush_segment(two)
            i += 2
            continue
        if ch in ";|&\n()`":
            flush_segment(ch)
            i += 1
            continue
        buf += ch
        i += 1
    flush_segment("")
    return segs


def head(tokens):
    """Command word and its arguments, with wrappers and assignments removed."""
    i, saw_prefix = 0, False
    while i < len(tokens):
        tok = tokens[i]
        if tok in PREFIX_SKIP:
            saw_prefix = True
            i += 1
            continue
        if ASSIGNMENT.match(tok):
            i += 1
            continue
        if saw_prefix and tok.startswith("-"):
            i += 1
            if tok in PREFIX_VALUE_FLAGS and i < len(tokens):
                i += 1                      # `sudo -u root cat …` -> `cat`
            continue
        break
    if i >= len(tokens):
        return None, []
    word = os.path.basename(tokens[i].rstrip("/")) or tokens[i]
    return word, tokens[i + 1:]


def without_redirects(args):
    """Arguments with redirection operators and their targets removed."""
    out, skip = [], False
    for tok in args:
        if skip:
            skip = False
            continue
        if REDIRECT.match(tok):
            skip = not REDIRECT_SELF.match(tok)   # `2>&1` carries its own target
            continue
        out.append(tok)
    return out


def operands(args, keep_read_targets=False):
    """Real arguments: flags and redirection targets dropped.

    `keep_read_targets` keeps the target of an INPUT redirect, because
    'cat < .env' really does read the file.
    """
    out, skip = [], False
    for tok in args:
        if skip:
            skip = False
            continue
        if REDIRECT.match(tok):
            # `2>&1` carries its own target: the next token is a real operand.
            skip = (not REDIRECT_SELF.match(tok)
                    and not (keep_read_targets and not WRITE_REDIRECT.match(tok)))
            continue
        if tok.startswith("-"):
            continue
        out.append(tok)
    return out


def is_secret_path(tok):
    base = os.path.basename(tok.rstrip("/")).lower()
    if not base or base.endswith(PLACEHOLDER_SUFFIXES):
        return False
    return any(fnmatch(base, g) for g in SECRET_GLOBS)


def judge(word, args, piped_words, depth):
    """One command in command position. Returns a reason or None."""
    if word is None or depth > MAX_DEPTH:
        return None

    if word in ("env", "printenv"):
        # `env` carrying a real command is a wrapper, not a dump — judge what it
        # runs (`env printenv` is a full dump). Only assignments and flags left
        # means nothing follows, and bare `env` prints the whole environment.
        # A redirection is not an argument: `env > /tmp/out` still dumps.
        tail = without_redirects(args)
        while tail and (ASSIGNMENT.match(tail[0]) or tail[0].startswith("-")):
            flag = tail.pop(0)
            if flag in ("-u", "--unset") and tail:
                tail.pop(0)
        if word == "env" and tail:
            inner_word, inner_args = head(tail)
            return judge(inner_word, inner_args, piped_words, depth + 1)
        if word == "printenv" and tail:
            return None                    # `printenv PATH`
        if any(w in FILTERS for w in piped_words):
            return None                    # `env | grep -c PATH`
        return ("§5: `%s` без фильтра выгружает всё окружение вместе со "
                "значениями секретов. %s" % (word, FIX))

    if word == "security":
        if "dump-keychain" in args:
            # No backticks around the whole command in this literal: inside double
            # quotes bash runs a backtick substitution, so the analyzer (rightly)
            # reads such a line as executing `security dump-keychain`.
            return "§5: security dump-keychain печатает содержимое связки ключей. " + FIX
        sub = next((a for a in operands(args)), "")
        if sub in ("find-generic-password", "find-internet-password"):
            if "-w" in args or "-g" in args:
                return ("§5: `security %s` с `-w`/`-g` печатает само значение пароля. %s"
                        % (sub, FIX))

    if word in SHELLS and "-c" in args:
        payload = args[args.index("-c") + 1:]
        if payload:
            return scan(payload[0], depth + 1)   # `bash -c 'printenv'`

    if word in READERS:
        for path in operands(args, keep_read_targets=True):
            if is_secret_path(path):
                return ("§5: чтение секретного файла `%s` командой `%s`. %s"
                        % (one_line(path), word, FIX))

    if word == "wp":
        pos = operands(args)
        if len(pos) >= 2 and pos[0] == "option" and pos[1] in ("get", "list"):
            # Judge the KEY only — the positional operand and `--search`; global
            # flags such as `--path=/srv/site` or `--user` are not option names.
            keys = list(pos[2:])
            tail = args[args.index(pos[1]) + 1:]
            for k, tok in enumerate(tail):
                if tok.startswith("--search="):
                    keys.append(tok.split("=", 1)[1])
                elif tok == "--search" and k + 1 < len(tail):
                    keys.append(tail[k + 1])
            for tok in keys:
                if any(w in tok.lower() for w in WP_SECRET_WORDS):
                    return ("§5: `wp option %s %s` печатает значение секретной опции. %s"
                            % (pos[1], one_line(tok), FIX))
    return None


def scan(command, depth=0):
    """Return a one-line reason when the CLOSED list is hit, else None."""
    if depth > MAX_DEPTH:
        return None
    body, expanded = strip_heredocs(command)
    segs = split_segments(body)

    for idx, (tokens, _) in enumerate(segs):
        word, args = head(tokens)
        # Only a PIPE makes the next command a filter of this one: after `;`
        # the dump has already printed.
        piped, k = [], idx
        while k < len(segs) and segs[k][1] == "|":
            k += 1
            if k < len(segs):
                piped.append(head(segs[k][0])[0])
        reason = judge(word, args, piped, depth)
        if reason:
            return reason

    # Command substitutions run before the outer command, including inside
    # double quotes and inside an unquoted heredoc body.
    for inner in substitutions(body) + substitutions(expanded):
        reason = scan(inner, depth + 1)
        if reason:
            return reason
    return None


def main():
    raw = sys.stdin.read()
    if not raw.strip():
        return ALLOW
    try:
        event = json.loads(raw)
    except Exception:
        note("вход не разобран как JSON")
        return ALLOW
    if not isinstance(event, dict):
        note("вход — не объект JSON")
        return ALLOW
    if event.get("tool_name") != "Bash":
        return ALLOW
    tool_input = event.get("tool_input")
    command = tool_input.get("command") if isinstance(tool_input, dict) else None
    if not isinstance(command, str) or not command.strip():
        return ALLOW
    reason = scan(command)
    if reason:
        # Collapse whitespace only: the values were capped in judge(), and a cap
        # over the WHOLE line cut off the "use ai-secret run" half on long paths.
        sys.stderr.write(re.sub(r"\s+", " ", reason).strip() + "\n")
        return BLOCK
    return ALLOW


try:
    sys.exit(main())
except SystemExit:
    raise
except Exception as exc:                                   # noqa: BLE001
    note("внутренняя ошибка анализатора (%s)" % type(exc).__name__)
    sys.exit(ALLOW)
SGUARD_PY

printf '%s' "$input" | python3 -c "$PF_SG_PY"
rc=$?

case "$rc" in
  0) exit 0 ;;
  2) exit 2 ;;
  *) note "анализатор завершился кодом $rc"; exit 0 ;;
esac
