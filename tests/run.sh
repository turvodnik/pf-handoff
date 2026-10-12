#!/usr/bin/env bash
# tests/run.sh — one-command test suite for the pf-handoff distribution
# (T-016, F-14). Everything here runs against THIS repo's own files
# (hooks/, skills/) — never the _tools canon. Unlike pf-workflow's sibling
# suite, nothing here is expected to be red: this repo's hooks/*.sh have no
# pending canon fix that changes observable behavior (checked by hand before
# writing this file — F-20's PF_EFFECTIVE_HOME rename is internal-only, see
# journal). `RESULT: GREEN` here means exactly that: everything passed.
#
# Bash 3.2 compatible (macOS system bash floor, same constraint as every
# other script in this family): no associative arrays, no ${var,,}, no
# mapfile, no $BASHPID.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
HOOKS_DIR="$ROOT/hooks"
BASH_BIN="$(command -v bash)"
FULL_PATH="$PATH"

PASS=0
FAIL=0
FAIL_LABELS=()
CURRENT_GROUP=""
GROUP_PASS=0
GROUP_FAIL=0
GROUP_SUMMARY=()

group() {
  if [ -n "$CURRENT_GROUP" ]; then
    GROUP_SUMMARY+=("$CURRENT_GROUP: $GROUP_PASS/$((GROUP_PASS + GROUP_FAIL))")
  fi
  CURRENT_GROUP="$1"; GROUP_PASS=0; GROUP_FAIL=0
  echo; echo "=== $1 ==="
}
pass() { PASS=$((PASS + 1)); GROUP_PASS=$((GROUP_PASS + 1)); echo "PASS  $1"; }
fail() {
  FAIL=$((FAIL + 1)); GROUP_FAIL=$((GROUP_FAIL + 1))
  echo "FAIL  $1"; [ -n "${2:-}" ] && echo "      $2"
  FAIL_LABELS+=("[$CURRENT_GROUP] $1")
}

echo "pf-handoff test suite"
echo "root: $ROOT"
echo "bash: $BASH_BIN ($("$BASH_BIN" --version | head -1))"

CLEANUP_DIRS=()
cleanup() {
  local d
  for d in "${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}"; do [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"; done
}
trap cleanup EXIT

# Portable temp helpers: GNU mktemp (Linux, incl. ubuntu-latest — the CI
# runner this suite ships for) rejects `-t <prefix>` unless <prefix> itself
# contains literal X's ("too few X's in template"); BSD mktemp (macOS, this
# suite's other target) accepts a bare prefix and appends randomness itself.
# An explicit template with X's is accepted, identically, by both. Verified
# on macOS and in `ubuntu:24.04` (docker) before relying on it everywhere.
pf_mktemp_file() { mktemp "${TMPDIR:-/tmp}/$1.XXXXXXXX"; }
pf_mktemp_dir()  { mktemp -d "${TMPDIR:-/tmp}/$1.XXXXXXXX"; }

mktempdir() { local d; d=$(pf_mktemp_dir pfho-tests); CLEANUP_DIRS+=("$d"); printf '%s' "$d"; }

# ===========================================================================
# --- reusable sweeps (parameterized by root, so the negative controls below
#     can point them at a mutated temp copy instead of the real repo) -------
# ===========================================================================

# find, not `git ls-files`: must also work against a temp copy with no .git.
list_sh_files() { find "$1" -name '*.sh' -not -path '*/.git/*' | sort; }

# bash_n_sweep <root> -> prints PASS/FAIL lines via the caller's pass/fail,
# returns 0 if every file is syntax-clean, 1 otherwise.
bash_n_sweep() {
  local root="$1" f bad=0 n=0 err
  err=$(pf_mktemp_file pfho-bashn-err)
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    n=$((n + 1))
    if ! "$BASH_BIN" -n "$f" 2>"$err"; then
      echo "      bash -n: ${f#"$root"/}: $(cat "$err")"
      bad=1
    fi
  done < <(list_sh_files "$root")
  rm -f "$err"
  echo "$n files checked"
  return "$bad"
}

# Runs ShellCheck across every .sh file under <root>: 0 = clean or
# unavailable, 1 = findings (also printed to stdout by the caller).
shellcheck_sweep() {
  local root="$1" files=()
  command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck not installed"; return 2; }
  while IFS= read -r f; do files+=("$f"); done < <(list_sh_files "$root")
  [ "${#files[@]}" -eq 0 ] && return 0
  shellcheck -S warning "${files[@]}"
}

group "bash -n (syntax) on every .sh file"
out=$(bash_n_sweep "$ROOT"); rc=$?
echo "$out" | tail -1
if [ "$rc" = 0 ]; then
  pass "bash -n clean on all files ($(echo "$out" | tail -1 | grep -oE '^[0-9]+'))"
else
  fail "bash -n found syntax error(s)" "$(echo "$out" | grep '^      ')"
fi

group "shellcheck -S warning on every .sh file"
sc_out=$(shellcheck_sweep "$ROOT" 2>&1); sc_rc=$?
case "$sc_rc" in
  0) pass "shellcheck clean on all files" ;;
  2) echo "SKIP  shellcheck not installed on this machine — install: brew install shellcheck" ;;
  *) fail "shellcheck found issue(s)" "$sc_out" ;;
esac

group "GitHub Actions workflow YAML is valid"
WF="$ROOT/.github/workflows/tests.yml"
if [ ! -f "$WF" ]; then
  fail "tests.yml not found at $WF"
else
  # Two independent sub-checks (strict-parse, actionlint) with separate
  # tools: neither's absence may swallow the other (T-017 fix round, 🔴 B).
  if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP  python3 not available — cannot strict-parse the workflow YAML"
  elif ! python3 -c "import yaml" >/dev/null 2>&1; then
    # python3 present, PyYAML missing: the stock python3 on ubuntu-24.04 and
    # on macOS's Command Line Tools both lack it. Previously this fell
    # through to the strict-parse below, which raised ModuleNotFoundError
    # and reported "tests.yml is not valid YAML" — blaming a valid file for
    # a missing third-party module, contradicting this exact SKIP contract.
    echo "SKIP  PyYAML not installed (python3 -c 'import yaml' failed) — cannot strict-parse the workflow YAML"
  else
    if err=$(python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1], encoding='utf-8'))" "$WF" 2>&1); then
      pass "tests.yml parses as valid YAML"
    else
      fail "tests.yml is not valid YAML" "$err"
    fi
  fi
  if command -v actionlint >/dev/null 2>&1; then
    if out=$(actionlint "$WF" 2>&1); then pass "actionlint clean"; else fail "actionlint finding(s)" "$out"; fi
  else
    echo "SKIP  actionlint not installed on this machine (optional per acceptance criteria)"
  fi
fi

# ===========================================================================
group "threshold-parity.sh (statusline <-> context-guard zone/HOME parity)"
# ===========================================================================
tp_out=$("$BASH_BIN" "$TESTS_DIR/threshold-parity.sh" 2>&1); tp_rc=$?
echo "$tp_out"
if [ "$tp_rc" = 0 ] && printf '%s' "$tp_out" | grep -q '^RESULT: GREEN$'; then
  pass "threshold-parity.sh: RESULT GREEN"
else
  fail "threshold-parity.sh: not green (rc=$tp_rc)"
fi

# ===========================================================================
group "guard-cases.sh (T-111/T-031): budget_tokens, advisor spike, autocheckpoint"
# ===========================================================================
gc_out=$("$BASH_BIN" "$TESTS_DIR/guard-cases.sh" 2>&1); gc_rc=$?
echo "$gc_out" | tail -4
if [ "$gc_rc" = 0 ] && printf '%s' "$gc_out" | grep -q '^RESULT: GREEN$'; then
  pass "guard-cases.sh: RESULT GREEN"
else
  fail "guard-cases.sh: not green (rc=$gc_rc)" "$(printf '%s' "$gc_out" | grep '^FAIL' | head -5)"
fi

# ===========================================================================
group "claims-check-probes.sh (T-030): write-claim matching, hostile battery"
# ===========================================================================
cc_probes="$TESTS_DIR/claims-check-probes.sh"
if [ ! -f "$cc_probes" ]; then
  fail "claims-check-probes.sh missing — claims-check.sh would ship untested"
else
  cc_out=$("$BASH_BIN" "$cc_probes" 2>&1); cc_rc=$?
  echo "$cc_out" | tail -3
  if [ "$cc_rc" = 0 ] && printf '%s' "$cc_out" | grep -q 'провалено 0$'; then
    pass "claims-check-probes.sh: $(printf '%s' "$cc_out" | tail -1)"
  else
    fail "claims-check-probes.sh: not green (rc=$cc_rc)" "$(printf '%s' "$cc_out" | grep '❌' | head -5)"
  fi
fi

# ===========================================================================
group "drift-check.sh level 1 (T-022, I-024): this repo vs a fresh sync-from-tools.sh"
# ===========================================================================
# Only meaningful in a dev clone under _tools/repos/pf-handoff, where the
# canon (skill-library/, context-hooks/) sits two levels up — never true for
# an end-user clone of this public repo, which has no _tools at all. Absent
# canon is a SKIP, not a FAIL: this repo's own suite must stay green for
# people who never heard of _tools (same contract as the other SKIP
# branches above).
DC_CANON="$ROOT/../../skill-library/tests/drift-check.sh"
if [ -f "$DC_CANON" ]; then
  # --repo-dir, not --repo: the checker must inspect THIS checkout ($ROOT),
# not guess $TOOLS/repos/<name> — in a worktree or symlinked layout those
# are different directories, and the suite would silently report on the
# wrong one (and stay green forever if the directory were renamed).
dc_out=$("$BASH_BIN" "$DC_CANON" --level 1 --repo-dir "$ROOT" 2>&1); dc_rc=$?
  echo "$dc_out"
  if [ "$dc_rc" = 0 ]; then
    pass "drift-check level 1: repo matches a fresh sync-from-tools.sh from canon"
  else
    fail "drift-check level 1 found drift between canon and this repo" "$dc_out"
  fi
else
  echo "SKIP  no _tools canon found at $DC_CANON — expected outside a _tools/repos dev clone"
fi

# ===========================================================================
group "non-blocking hooks never crash: garbage stdin x {jq-only, python3-only, neither} x env -u HOME"
# ===========================================================================
# Three curated PATH variants isolate which JSON reader branch actually ran
# (context-guard.sh and statusline.sh both branch on `command -v jq`) — a dev
# machine with jq installed would otherwise never exercise the python3-only
# branch at all.
#
# precompact.sh is NOT in this group any more, and that is a contract change,
# not a relaxation. It is the one hook allowed to stop something: since the
# compaction gate landed, "the snapshot was not written" must produce exit 2
# (documented as "blocks compaction") instead of a silent rc=0. Its own
# group below asserts the stricter behavior — blocked AND loud — plus the
# positive control that it stays out of the way when the snapshot succeeds.
# The three hooks left here still owe the old promise: never interfere.
BASE_TOOLS="bash cat date dirname mkdir sed grep tr printf mv rm mktemp head tail sort wc find"
mkminpath() {
  local d="$1"; shift
  mkdir -p "$d"
  local t src
  for t in $BASE_TOOLS; do
    src="$(PATH="$FULL_PATH" command -v "$t" 2>/dev/null)" || { echo "harness setup: '$t' not found" >&2; exit 90; }
    ln -sf "$src" "$d/$t"
  done
  for t in "$@"; do
    src="$(PATH="$FULL_PATH" command -v "$t" 2>/dev/null)" || { echo "harness setup: '$t' not found, cannot build this PATH variant" >&2; exit 90; }
    ln -sf "$src" "$d/$t"
  done
}
MP_JQ="$(mktempdir)"; mkminpath "$MP_JQ" jq
MP_PY="$(mktempdir)"; mkminpath "$MP_PY" python3
MP_NONE="$(mktempdir)"; mkminpath "$MP_NONE"

for variant_name in jq-only python3-only neither; do
  case "$variant_name" in
    jq-only) mp="$MP_JQ" ;;
    python3-only) mp="$MP_PY" ;;
    neither) mp="$MP_NONE" ;;
  esac
  for hook in statusline.sh context-guard.sh sessionstart.sh; do
    home_ok="$(mktempdir)"
    out=$(printf 'garbage \x00 not json { [' | PATH="$mp" HOME="$home_ok" "$mp/bash" "$HOOKS_DIR/$hook" 2>&1)
    rc=$?
    if [ "$rc" = 0 ] && [ -z "$out" ]; then
      pass "$hook ($variant_name, garbage stdin, HOME set) -> rc=0, silent"
    else
      fail "$hook ($variant_name, garbage stdin, HOME set) -> rc=$rc" "$out"
    fi

    home_nohome="$(mktempdir)"
    out=$(printf 'more garbage' | env -u HOME PATH="$mp" TMPDIR="$home_nohome" "$mp/bash" "$HOOKS_DIR/$hook" 2>&1)
    rc=$?
    if [ "$rc" = 0 ] && [ -z "$out" ]; then
      pass "$hook ($variant_name, garbage stdin, env -u HOME) -> rc=0, silent"
    else
      fail "$hook ($variant_name, garbage stdin, env -u HOME) -> rc=$rc" "$out"
    fi
  done
done

# ===========================================================================
group "precompact.sh gate: blocks loudly without a snapshot, stays out of the way with one, ignores foreign input"
# ===========================================================================
# The contract this group pins down (decided in T-033, narrowed in T-166,
# documented in docs/context-rules.md "Automatic snapshot and the gate before
# compaction"):
#
#   * snapshot written                    -> rc=0, silent, compaction proceeds;
#   * Claude payload (raw text contains a "session_id" key) but the snapshot
#     could NOT be written                -> rc=2 AND a human-readable reason
#     on stderr. Silence would be the failure this gate exists to prevent:
#     compacting while nothing was preserved, and looking exactly like success;
#   * unrecognised or foreign input (garbage, another platform's payload such
#     as camelCase `sessionId`; no "session_id" key in the raw text)
#                                         -> rc=0 and complete silence: the
#     gate is not ours to apply there, so it neither blocks nor logs (T-166).
#
# Recognition is done on the RAW text, not on the parsed value. That is why
# the `neither` PATH variant below still blocks a perfectly valid Claude
# payload: jq or python3 is effectively a requirement of the gate for Claude
# input, and this test states it out loud rather than leaving it to be
# discovered on a bare machine. Garbage in that same variant is simply not
# the gate's business and passes through silently.
BLOCK_MARK="COMPACTION STOPPED"
GOOD_PAYLOAD='{"session_id":"t033-gate","trigger":"manual","cwd":"","transcript_path":""}'

for variant_name in jq-only python3-only neither; do
  case "$variant_name" in
    jq-only) mp="$MP_JQ" ;;
    python3-only) mp="$MP_PY" ;;
    neither) mp="$MP_NONE" ;;
  esac

  # --- garbage stdin: not a Claude payload -> not ours to gate -> rc=0, silent
  home_ok="$(mktempdir)"
  out=$(printf 'garbage \x00 not json { [' | PATH="$mp" HOME="$home_ok" "$mp/bash" "$HOOKS_DIR/precompact.sh" 2>&1)
  rc=$?
  if [ "$rc" = 0 ] && [ -z "$out" ]; then
    pass "precompact.sh ($variant_name, garbage stdin, HOME set) -> rc=0, silent (foreign input is not gated)"
  else
    fail "precompact.sh ($variant_name, garbage stdin, HOME set) -> rc=$rc, output not empty or rc != 0" "$out"
  fi

  home_nohome="$(mktempdir)"
  out=$(printf 'more garbage' | env -u HOME PATH="$mp" TMPDIR="$home_nohome" "$mp/bash" "$HOOKS_DIR/precompact.sh" 2>&1)
  rc=$?
  if [ "$rc" = 0 ] && [ -z "$out" ]; then
    pass "precompact.sh ($variant_name, garbage stdin, env -u HOME) -> rc=0, silent (foreign input is not gated)"
  else
    fail "precompact.sh ($variant_name, garbage stdin, env -u HOME) -> rc=$rc, output not empty or rc != 0" "$out"
  fi

  # --- foreign platform payload (camelCase sessionId): also silent rc=0 ----
  out=$(printf '{"sessionId":"x-foreign","hook_event_name":"PreCompact"}' | PATH="$mp" HOME="$(mktempdir)" "$mp/bash" "$HOOKS_DIR/precompact.sh" 2>&1)
  rc=$?
  if [ "$rc" = 0 ] && [ -z "$out" ]; then
    pass "precompact.sh ($variant_name, foreign camelCase sessionId payload) -> rc=0, silent"
  else
    fail "precompact.sh ($variant_name, foreign payload) -> rc=$rc, output not empty or rc != 0" "$out"
  fi

  # --- positive control: Claude-shaped but unparseable payload still blocks --
  # "session_id" is present in the raw text, so the gate recognises it as
  # Claude's; the JSON is broken, so no session id (and no snapshot) results.
  # Must stay rc=2 + reason: this is what keeps the flip above honest.
  out=$(printf '{"session_id": "trunc' | PATH="$mp" HOME="$(mktempdir)" "$mp/bash" "$HOOKS_DIR/precompact.sh" 2>&1)
  rc=$?
  case "$out" in *"$BLOCK_MARK"*) loud=1 ;; *) loud=0 ;; esac
  if [ "$rc" = 2 ] && [ "$loud" = 1 ]; then
    pass "precompact.sh ($variant_name, Claude-shaped unparseable payload) -> rc=2 + reason on stderr"
  else
    fail "precompact.sh ($variant_name, Claude-shaped unparseable payload) -> rc=$rc, loud=$loud" "$out"
  fi

  # --- valid payload, writable HOME ---------------------------------------
  # With a parser: the snapshot lands in the emergency directory (cwd is
  # empty, so the project path is skipped) and compaction goes ahead.
  # Without one: same block as garbage, and for the same honest reason.
  home_good="$(mktempdir)"
  out=$(printf '%s' "$GOOD_PAYLOAD" | PATH="$mp" HOME="$home_good" "$mp/bash" "$HOOKS_DIR/precompact.sh" 2>&1)
  rc=$?
  snap_dir="$home_good/.claude/context-state/handoff"
  snap_count=$(find "$snap_dir" -name '*t033-gate*.md' 2>/dev/null | wc -l | tr -d ' ')
  if [ "$variant_name" = neither ]; then
    case "$out" in *"$BLOCK_MARK"*) loud=1 ;; *) loud=0 ;; esac
    if [ "$rc" = 2 ] && [ "$loud" = 1 ] && [ "$snap_count" = 0 ]; then
      pass "precompact.sh (neither, valid payload) -> rc=2 + reason: no jq/python3 means no snapshot is possible"
    else
      fail "precompact.sh (neither, valid payload) -> rc=$rc, loud=$loud, snapshots=$snap_count" "$out"
    fi
  else
    if [ "$rc" = 0 ] && [ -z "$out" ] && [ "$snap_count" = 1 ]; then
      pass "precompact.sh ($variant_name, valid payload, writable HOME) -> rc=0, silent, snapshot written"
    else
      fail "precompact.sh ($variant_name, valid payload) -> rc=$rc, snapshots=$snap_count" "$out"
    fi
  fi
done

# --- negative control: the gate must go red when writing is impossible -----
# Nothing about the payload changes — only the writability of the one place
# the snapshot could land. If this stayed rc=0, the passes above would be
# proving nothing but "the hook exits 0 a lot".
home_ro="$(mktempdir)"
chmod 500 "$home_ro"
out=$(printf '%s' "$GOOD_PAYLOAD" | PATH="$MP_JQ" HOME="$home_ro" "$MP_JQ/bash" "$HOOKS_DIR/precompact.sh" 2>&1)
rc=$?
chmod 700 "$home_ro"
case "$out" in *"$BLOCK_MARK"*) loud=1 ;; *) loud=0 ;; esac
if [ "$rc" = 2 ] && [ "$loud" = 1 ]; then
  pass "negative control: same valid payload into a read-only HOME -> rc=2 + reason on stderr"
else
  fail "negative control: read-only HOME -> rc=$rc, loud=$loud" "$out"
fi

# --- empty stdin: allowed through, but never without a trace ---------------
# Decided in T-033's fix round: a zero-length payload is not a compaction
# event (the harness always sends JSON; the registration wrapper drains stdin
# without calling the hook when the script is unavailable), and blocking here
# would recreate the very wedge the /bin/sh registration caused on Debian.
# Silence, though, was the old bug: no snapshot AND no log line meant nobody
# could tell afterwards that the safety net had not fired.
home_empty="$(mktempdir)"
out=$(printf '' | PATH="$MP_JQ" HOME="$home_empty" "$MP_JQ/bash" "$HOOKS_DIR/precompact.sh" 2>&1)
rc=$?
log_line=$(grep -c 'SKIPPED-empty-stdin' "$home_empty/.claude/context-state/compacts.log" 2>/dev/null || true)
if [ "$rc" = 0 ] && [ -z "$out" ] && [ "${log_line:-0}" -ge 1 ]; then
  pass "precompact.sh (empty stdin) -> rc=0, silent, but SKIPPED-empty-stdin logged"
else
  fail "precompact.sh (empty stdin) -> rc=$rc, log lines=$log_line" "$out"
fi

# --- subagent session: no snapshot by design, and the log must say so ------
# `OK ?` used to be logged here — indistinguishable from "snapshot written".
home_sub="$(mktempdir)"
out=$(printf '{"session_id":"agent-t033","trigger":"auto","cwd":"","transcript_path":""}' \
  | PATH="$MP_JQ" HOME="$home_sub" "$MP_JQ/bash" "$HOOKS_DIR/precompact.sh" 2>&1)
rc=$?
sub_line=$(grep -c 'SKIPPED-subagent' "$home_sub/.claude/context-state/compacts.log" 2>/dev/null || true)
if [ "$rc" = 0 ] && [ "${sub_line:-0}" -ge 1 ]; then
  pass "precompact.sh (subagent session) -> rc=0 and logged as SKIPPED-subagent, not 'OK ?'"
else
  fail "precompact.sh (subagent session) -> rc=$rc, SKIPPED-subagent lines=$sub_line" "$out"
fi

# ===========================================================================
group "sessionstart.sh picks up a live HANDOFF even with no HOME in the environment (F-20)"
# ===========================================================================
# The garbage-stdin sweep above never reaches the $HOME lines: it exits early
# on `case "$source"`. So an unset HOME under `set -u` killed the script right
# where it mattered, the error was swallowed by the wrapper, and the outcome
# looked exactly like "no live cheat-sheets" — the silent loss F-20 fixed in
# the other three hooks and missed in this one.
ss_proj="$(mktempdir)"
mkdir -p "$ss_proj/.agents/runtime/handoff"
printf -- '---\nstatus: active\ntask: T-000\n---\n\n## State\nprobe\n' \
  > "$ss_proj/.agents/runtime/handoff/$(date +%Y-%m-%d)-probe.md"
ss_tmp="$(mktempdir)"
ss_payload="$(printf '{"source":"startup","cwd":"%s","session_id":"t033-ss"}' "$ss_proj")"
out=$(printf '%s' "$ss_payload" | env -u HOME TMPDIR="$ss_tmp" "$BASH_BIN" "$HOOKS_DIR/sessionstart.sh" 2>&1)
rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'additionalContext' && printf '%s' "$out" | grep -q 'probe.md'; then
  pass "sessionstart.sh (env -u HOME, live HANDOFF) -> the cheat-sheet is still reported"
else
  fail "sessionstart.sh (env -u HOME) -> rc=$rc, no HANDOFF in output" "$out"
fi
out=$(printf '%s' "$ss_payload" | HOME="$ss_tmp" "$BASH_BIN" "$HOOKS_DIR/sessionstart.sh" 2>&1)
rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'probe.md'; then
  pass "sessionstart.sh (HOME set, live HANDOFF) -> the cheat-sheet is reported"
else
  fail "sessionstart.sh (HOME set) -> rc=$rc, no HANDOFF in output" "$out"
fi

# ===========================================================================
group "sessionstart.sh warns when cwd is not a project (Р14/I-077)"
# ===========================================================================
# A session started from a stray or empty folder used to work in total
# silence: no AGENTS.md, no .agents/ -> nothing tells the agent that
# checkpoints and claims are about to land in the global ~/.claude folders
# instead of the project. Inside a live Claude Code session CLAUDE_PROJECT_DIR
# is set and the payload's cwd is ignored, so every probe here must run with
# `env -u CLAUDE_PROJECT_DIR` — same pattern the HOME probes above use for HOME.
ss_warn_home="$(mktempdir)"
ss_bare="$(mktempdir)"
ss_bare_payload="$(printf '{"source":"startup","cwd":"%s","session_id":"t132-ss"}' "$ss_bare")"
out=$(printf '%s' "$ss_bare_payload" | env -u CLAUDE_PROJECT_DIR HOME="$ss_warn_home" "$BASH_BIN" "$HOOKS_DIR/sessionstart.sh" 2>&1)
rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'cwd не проект'; then
  pass "sessionstart.sh (empty cwd, no AGENTS.md/.agents) -> warns 'cwd не проект'"
else
  fail "sessionstart.sh (empty cwd) -> rc=$rc, no warning in output" "$out"
fi

ss_named="$(mktempdir)"
: > "$ss_named/AGENTS.md"
ss_named_payload="$(printf '{"source":"startup","cwd":"%s","session_id":"t132-ss2"}' "$ss_named")"
out=$(printf '%s' "$ss_named_payload" | env -u CLAUDE_PROJECT_DIR HOME="$ss_warn_home" "$BASH_BIN" "$HOOKS_DIR/sessionstart.sh" 2>&1)
rc=$?
if [ "$rc" = 0 ] && ! printf '%s' "$out" | grep -q 'cwd не проект'; then
  pass "sessionstart.sh (cwd has AGENTS.md, negative control) -> no warning"
else
  fail "sessionstart.sh (cwd has AGENTS.md) -> rc=$rc, unexpected warning" "$out"
fi

# ===========================================================================
group "hooks run the way install.sh actually registers them (POSIX /bin/sh, i.e. dash on Debian/Ubuntu)"
# ===========================================================================
# The blind spot this group exists to close (found by the independent QA of
# v1.10.0): every other group here starts a hook with an explicit `bash …`,
# but Claude Code runs the registered command through the SYSTEM SHELL. On
# macOS /bin/sh is bash in POSIX mode, so nothing showed; on Debian/Ubuntu it
# is dash, and a wrapper that said `/bin/sh '<hook>'` ignored the #!/bin/bash
# shebang — every hook died on the first bash-ism with rc=2. rc=2 is not
# "did nothing": PreCompact rc=2 blocks the compaction, UserPromptSubmit rc=2
# erases the user's prompt. The whole Linux install was wedged while CI (on
# ubuntu-latest!) stayed green, because CI called `bash tests/run.sh`.
#
# So: take the command string OUT of a settings.json that install.sh just
# wrote (never a reconstruction — the reconstruction is what CI was testing),
# and execute it with a real POSIX shell.
SH_BIN=""
for cand in /bin/dash /bin/sh; do [ -x "$cand" ] && { SH_BIN="$cand"; break; }; done
if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP  python3 not available — cannot read commands back out of settings.json"
elif [ -z "$SH_BIN" ]; then
  echo "SKIP  no POSIX shell found at /bin/dash or /bin/sh"
else
  # Is this /bin/sh actually POSIX-only, or bash wearing the name? Decides
  # whether the negative control below can prove anything at all.
  if "$SH_BIN" -c 'cat <<< x' >/dev/null 2>&1; then posix_strict=0; else posix_strict=1; fi
  echo "shell under test: $SH_BIN (bash-isms rejected: $posix_strict)"

  sh_sandbox="$(mktempdir)"
  sh_settings="$sh_sandbox/settings.json"
  CLAUDE_SETTINGS_PATH="$sh_settings" "$BASH_BIN" "$HOOKS_DIR/install.sh" >/dev/null 2>&1

  # <event-or-statusLine> <marker> -> the registered command string
  reg_cmd() {
    python3 - "$sh_settings" "$1" "$2" <<'PYEOF'
import json, sys
path, key, marker = sys.argv[1:4]
d = json.load(open(path, encoding="utf-8"))
if key == "statusLine":
    print(d.get("statusLine", {}).get("command", ""))
    raise SystemExit
for item in d.get("hooks", {}).get(key, []):
    for h in item.get("hooks", []):
        c = h.get("command") or ""
        if marker in c:
            print(c)
            raise SystemExit
print("")
PYEOF
  }

  # --- the one that can block: PreCompact on a healthy path ----------------
  pc_cmd="$(reg_cmd PreCompact /precompact.sh)"
  if [ -z "$pc_cmd" ]; then
    fail "no PreCompact command found in the settings.json install.sh just wrote"
  else
    home_sh="$(mktempdir)"
    out=$(printf '{"session_id":"t033-sh","trigger":"manual","cwd":"","transcript_path":""}' \
      | HOME="$home_sh" "$SH_BIN" -c "$pc_cmd" 2>&1)
    rc=$?
    snaps=$(find "$home_sh/.claude/context-state/handoff" -name '*t033-sh*.md' 2>/dev/null | wc -l | tr -d ' ')
    if [ "$rc" = 0 ] && [ -z "$out" ] && [ "$snaps" = 1 ]; then
      pass "registered PreCompact command under $SH_BIN -> rc=0, silent, snapshot written"
    else
      fail "registered PreCompact command under $SH_BIN -> rc=$rc, snapshots=$snaps" "$out"
    fi
  fi

  # --- the other three: registered form must not crash them -----------------
  sh_probe() {
    local label="$1" key="$2" marker="$3" payload="$4"
    local cmd home out rc
    cmd="$(reg_cmd "$key" "$marker")"
    if [ -z "$cmd" ]; then fail "no $key command found in settings.json ($marker)"; return; fi
    home="$(mktempdir)"
    out=$(printf '%s' "$payload" | HOME="$home" "$SH_BIN" -c "$cmd" 2>&1); rc=$?
    if [ "$rc" = 0 ]; then
      pass "registered $label command under $SH_BIN -> rc=0"
    else
      fail "registered $label command under $SH_BIN -> rc=$rc" "$out"
    fi
  }
  sh_probe "SessionStart"      SessionStart     /sessionstart.sh  '{"source":"startup","cwd":"","session_id":"t033-sh"}'
  sh_probe "UserPromptSubmit"  UserPromptSubmit /context-guard.sh '{"session_id":"t033-sh","cwd":"","transcript_path":""}'
  sh_probe "statusLine"        statusLine       /statusline.sh    '{"session_id":"t033-sh","workspace":{"current_dir":""}}'

  # --- negative control: the pre-fix wrapper must go red here --------------
  # Same hook, same payload, only the wrapper reverted to the old form — the
  # one that named no interpreter and let `/bin/sh` decide. $SH_BIN is written
  # in literally because that IS what /bin/sh resolves to on Debian/Ubuntu;
  # spelling `/bin/sh` here would silently re-enter bash on macOS and the
  # control would pass for the wrong reason (it did, on the first run of this
  # very group). If this stayed green, the passes above would be proving
  # nothing but "our hooks exit 0 a lot".
  if [ "$posix_strict" = 1 ]; then
    old_cmd="if [ -f '$HOOKS_DIR/precompact.sh' ]; then $SH_BIN '$HOOKS_DIR/precompact.sh'; fi"
    home_old="$(mktempdir)"
    out=$(printf '{"session_id":"t033-old","trigger":"manual","cwd":"","transcript_path":""}' \
      | HOME="$home_old" "$SH_BIN" -c "$old_cmd" 2>&1)
    rc=$?
    if [ "$rc" != 0 ]; then
      pass "negative control: the old /bin/sh wrapper under $SH_BIN -> rc=$rc (this is the Linux breakage)"
    else
      fail "negative control: old /bin/sh wrapper survived $SH_BIN — control is not sensitive" "$out"
    fi
  else
    echo "SKIP  $SH_BIN accepts bash-isms (it is bash in POSIX mode) — the old-wrapper negative control cannot prove anything here"
  fi
fi

# ===========================================================================
group "install.sh is idempotent (double run into a sandbox settings.json)"
# ===========================================================================
sandbox="$(mktempdir)"
settings="$sandbox/settings.json"
printf '{"existing":{"orca/agent-hooks":"marker, must survive untouched"}}\n' > "$settings"
run1_log="$(pf_mktemp_file pfho-install-run1)"
CLAUDE_SETTINGS_PATH="$settings" "$BASH_BIN" "$HOOKS_DIR/install.sh" > "$run1_log" 2>&1; run1_rc=$?
after1="$(pf_mktemp_file pfho-install-after1)"; cp "$settings" "$after1"
run2_log="$(pf_mktemp_file pfho-install-run2)"
CLAUDE_SETTINGS_PATH="$settings" "$BASH_BIN" "$HOOKS_DIR/install.sh" > "$run2_log" 2>&1; run2_rc=$?
after2="$(pf_mktemp_file pfho-install-after2)"; cp "$settings" "$after2"

if [ "$run1_rc" = 0 ] && [ "$run2_rc" = 0 ] && diff -q "$after1" "$after2" >/dev/null 2>&1; then
  pass "install.sh double run -> byte-identical settings.json (rc=$run1_rc, rc=$run2_rc)"
else
  fail "install.sh double run -> not idempotent (rc1=$run1_rc rc2=$run2_rc)" "$(diff "$after1" "$after2" 2>&1 | head -20)"
fi
if grep -q 'orca/agent-hooks' "$after2" 2>/dev/null; then
  pass "install.sh preserved the pre-existing (Orca) settings.json entry"
else
  fail "install.sh dropped an unrelated pre-existing settings.json entry"
fi
rm -f "$run1_log" "$run2_log" "$after1" "$after2"

# ===========================================================================
group "install.sh upgrades ITS OWN stale entry (the documented update path)"
# ===========================================================================
# `git pull && bash install.sh` is what README tells people to do to update.
# With add-if-missing it did nothing for someone who already had the old
# `/bin/sh` registration — "an entry mentioning precompact.sh exists" read as
# "installed", so the Linux breakage would have survived the fix that repairs
# it. The entry is now replaced; a foreign (Orca) entry still must not be.
upg_sandbox="$(mktempdir)"
upg_settings="$upg_sandbox/settings.json"
cat > "$upg_settings" <<'JSONEOF'
{
  "hooks": {
    "PreCompact": [
      {"hooks": [{"type": "command", "command": "if [ -f '/old/path/precompact.sh' ]; then /bin/sh '/old/path/precompact.sh'; fi", "timeout": 10}]}
    ],
    "UserPromptSubmit": [
      {"hooks": [{"type": "command", "command": "/bin/sh '/Users/x/.orca/agent-hooks/claude-hook.sh'", "timeout": 10}]}
    ]
  }
}
JSONEOF
CLAUDE_SETTINGS_PATH="$upg_settings" "$BASH_BIN" "$HOOKS_DIR/install.sh" >/dev/null 2>&1; upg_rc=$?
if command -v python3 >/dev/null 2>&1; then
  upg_report=$(python3 - "$upg_settings" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
pc = [h.get("command", "") for it in d["hooks"]["PreCompact"] for h in it.get("hooks", [])]
ups = [h.get("command", "") for it in d["hooks"]["UserPromptSubmit"] for h in it.get("hooks", [])]
mine = [c for c in pc if "/precompact.sh" in c]
print("count=%d" % len(mine))
print("stale=%d" % len([c for c in mine if "/old/path" in c]))
print("bash=%d" % len([c for c in mine if "; then bash '" in c]))
print("orca=%d" % len([c for c in ups if "orca/agent-hooks" in c]))
PYEOF
)
  echo "$upg_report" | tr '\n' ' '; echo
  if [ "$upg_rc" = 0 ] \
     && printf '%s' "$upg_report" | grep -q 'count=1' \
     && printf '%s' "$upg_report" | grep -q 'stale=0' \
     && printf '%s' "$upg_report" | grep -q 'bash=1' \
     && printf '%s' "$upg_report" | grep -q 'orca=1'; then
    pass "install.sh replaced its own stale /bin/sh entry with the bash form, left Orca's alone"
  else
    fail "install.sh did not upgrade its stale entry (rc=$upg_rc)" "$upg_report"
  fi
else
  echo "SKIP  python3 not available — cannot inspect the merged settings.json"
fi

# ===========================================================================
group "install.sh keeps someone else's registration (T-187): KEPT, --force, missing file, doctor"
# ===========================================================================
# A registration of our hook (or the statusLine) that points at an EXISTING
# file outside this clone is someone else's wiring — a canon checkout, another
# copy, a user's own status line. install.sh must leave it and say KEPT;
# --force points it here; a registration whose file is gone is ours to fix.
# Run on two curated PATHs: with jq (the jq merge) and without (the python3
# merge a stock machine without jq takes) — both must honour the decision.
kept_settings() { # kept_settings <file> <dir with the foreign scripts>
  cat > "$1" <<JSONEOF
{
  "statusLine": {"type": "command", "command": "bash $2/my-status.sh"},
  "hooks": {
    "UserPromptSubmit": [
      {"matcher": "*", "hooks": [{"type": "command", "command": "bash $2/context-guard.sh", "timeout": 10}]}
    ],
    "PreCompact": [
      {"hooks": [{"type": "command", "command": "if [ -f '$2/precompact.sh' ] && [ -r '$2/precompact.sh' ] && [ -x '$2/precompact.sh' ] && command -v bash >/dev/null 2>&1; then bash '$2/precompact.sh'; else { command -p cat 2>/dev/null || cat; } >/dev/null 2>&1 || :; fi", "timeout": 30}]}
    ]
  }
}
JSONEOF
}
# reg_report <settings> — "<event>=<the path its command names>" per line.
reg_report() {
  python3 - "$1" <<'PYEOF'
import json, re, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
def first_path(cmd):
    m = re.search(r"'([^']*/[^']*)'|(/[^\s;']+)", cmd or "")
    return (m.group(1) or m.group(2)) if m else ""
print("statusLine=" + first_path((d.get("statusLine") or {}).get("command")))
for evt in ("UserPromptSubmit", "PostToolUse", "SessionStart", "PreCompact"):
    cmds = [h.get("command", "") for it in d.get("hooks", {}).get(evt, []) for h in it.get("hooks", [])]
    print("%s=%s" % (evt, ",".join(first_path(c) for c in cmds)))
PYEOF
}
if command -v python3 >/dev/null 2>&1; then
  kp_root="$(mktempdir)"
  kp_foreign="$kp_root/canon"; mkdir -p "$kp_foreign"
  # A canon-like copy: all four of our hook scripts sit together (N4 tells such
  # a copy from another tool's same-name file by these neighbours).
  for n in context-guard.sh precompact.sh sessionstart.sh autocheckpoint.sh my-status.sh; do printf '#!/bin/bash\nexit 0\n' > "$kp_foreign/$n"; chmod +x "$kp_foreign/$n"; done
  if PATH="$FULL_PATH" command -v jq >/dev/null 2>&1; then mkminpath "$kp_root/path-jq" cp python3 jq; fi
  mkminpath "$kp_root/path-nojq" cp python3
  for variant in jq nojq; do
    vp="$kp_root/path-$variant"
    if [ "$variant" = jq ] && [ ! -e "$vp/jq" ]; then echo "SKIP  jq not installed — the jq merge branch is not exercised here"; continue; fi
    # 1) KEPT: three foreign registrations survive, the two others are ours.
    s="$kp_root/kept-$variant.json"; kept_settings "$s" "$kp_foreign"
    k_out=$(PATH="$vp" HOME="$kp_root" CLAUDE_SETTINGS_PATH="$s" "$BASH_BIN" "$HOOKS_DIR/install.sh" 2>&1); k_rc=$?
    k_rep=$(reg_report "$s")
    if [ "$k_rc" = 0 ] \
       && printf '%s\n' "$k_rep" | grep -qxF "statusLine=$kp_foreign/my-status.sh" \
       && printf '%s\n' "$k_rep" | grep -qxF "UserPromptSubmit=$kp_foreign/context-guard.sh" \
       && printf '%s\n' "$k_rep" | grep -qxF "PreCompact=$kp_foreign/precompact.sh" \
       && printf '%s\n' "$k_rep" | grep -qxF "PostToolUse=$HOOKS_DIR/context-guard.sh" \
       && printf '%s\n' "$k_rep" | grep -qxF "SessionStart=$HOOKS_DIR/sessionstart.sh" \
       && printf '%s\n' "$k_out" | grep -qxF "KEPT: statusLine → $kp_foreign/my-status.sh (registered elsewhere; re-run with --force to point it at this clone)" \
       && printf '%s\n' "$k_out" | grep -qxF "KEPT: UserPromptSubmit → $kp_foreign/context-guard.sh (registered elsewhere; re-run with --force to point it at this clone)" \
       && printf '%s\n' "$k_out" | grep -qxF "KEPT: PreCompact → $kp_foreign/precompact.sh (registered elsewhere; re-run with --force to point it at this clone)" \
       && grep -q '"timeout": 30' "$s"; then
      pass "[$variant] KEPT: foreign statusLine, UserPromptSubmit (bash <path>) and PreCompact (guard wrapper) stay, KEPT lines printed; PostToolUse/SessionStart point here"
    else
      fail "[$variant] KEPT: a foreign registration was overwritten or not reported (rc=$k_rc)" "$k_out | $k_rep"
    fi
    # 2) doctor accepts the kept wiring and names the paths.
    d_out=$(PATH="$vp" CLAUDE_SETTINGS_PATH="$s" HOME="$kp_root" "$BASH_BIN" "$HOOKS_DIR/doctor.sh" 2>&1); d_rc=$?
    if [ "$d_rc" = 0 ] \
       && printf '%s\n' "$d_out" | grep -qF "OK   KEPT: statusLine → $kp_foreign/my-status.sh" \
       && printf '%s\n' "$d_out" | grep -qF "OK   KEPT: UserPromptSubmit → $kp_foreign/context-guard.sh" \
       && printf '%s\n' "$d_out" | grep -qF "OK   PostToolUse points at our context-guard.sh"; then
      pass "[$variant] doctor.sh: kept registrations are OK and named by path, rc 0"
    else
      fail "[$variant] doctor.sh did not accept the kept registrations (rc=$d_rc)" "$d_out"
    fi
    # 3) --force: everything points at this clone, no KEPT line.
    s="$kp_root/force-$variant.json"; kept_settings "$s" "$kp_foreign"
    f_out=$(PATH="$vp" HOME="$kp_root" CLAUDE_SETTINGS_PATH="$s" "$BASH_BIN" "$HOOKS_DIR/install.sh" --force 2>&1); f_rc=$?
    f_rep=$(reg_report "$s")
    if [ "$f_rc" = 0 ] && ! printf '%s' "$f_out" | grep -q '^KEPT' && ! grep -qF "$kp_foreign" "$s" \
       && printf '%s\n' "$f_out" | grep -qxF "REPLACED: statusLine bash $kp_foreign/my-status.sh → $HOOKS_DIR/statusline.sh" \
       && printf '%s\n' "$f_out" | grep -qxF "REPLACED: UserPromptSubmit bash $kp_foreign/context-guard.sh → $HOOKS_DIR/context-guard.sh" \
       && printf '%s\n' "$f_out" | grep -q "^REPLACED: PreCompact if \[ -f '$kp_foreign/precompact.sh' \].* → $HOOKS_DIR/precompact.sh$" \
       && [ "$(printf '%s\n' "$f_out" | grep -c '^REPLACED: ')" = 3 ] \
       && printf '%s\n' "$f_rep" | grep -qxF "statusLine=$HOOKS_DIR/statusline.sh" \
       && printf '%s\n' "$f_rep" | grep -qxF "UserPromptSubmit=$HOOKS_DIR/context-guard.sh" \
       && printf '%s\n' "$f_rep" | grep -qxF "PreCompact=$HOOKS_DIR/precompact.sh"; then
      pass "[$variant] --force: every registration points at this clone, no KEPT line, REPLACED x3 names the old command (N4)"
    else
      fail "[$variant] --force did not repoint the foreign registrations (rc=$f_rc)" "$f_out | $f_rep"
    fi
    # 4) the registered file is gone -> upsert as before (ours to repair).
    s="$kp_root/gone-$variant.json"; kept_settings "$s" "$kp_root/gone"
    g_out=$(PATH="$vp" HOME="$kp_root" CLAUDE_SETTINGS_PATH="$s" "$BASH_BIN" "$HOOKS_DIR/install.sh" 2>&1); g_rc=$?
    g_rep=$(reg_report "$s")
    if [ "$g_rc" = 0 ] && ! printf '%s' "$g_out" | grep -q '^KEPT' \
       && printf '%s\n' "$g_rep" | grep -qxF "statusLine=$HOOKS_DIR/statusline.sh" \
       && printf '%s\n' "$g_rep" | grep -qxF "UserPromptSubmit=$HOOKS_DIR/context-guard.sh" \
       && printf '%s\n' "$g_rep" | grep -qxF "PreCompact=$HOOKS_DIR/precompact.sh" \
       && grep -q '"timeout": 30' "$s"; then
      pass "[$variant] registered file missing -> upsert to this clone (manual timeout 30 kept), no KEPT line"
    else
      fail "[$variant] a registration pointing at a missing file was not repaired (rc=$g_rc)" "$g_out | $g_rep"
    fi
    # 4b) a statusLine command with NO file path (npx ccusage statusline) is
    #     the user's own choice: KEPT without --force, ours with --force.
    s="$kp_root/npx-$variant.json"
    printf '{"statusLine":{"type":"command","command":"npx ccusage statusline"}}' > "$s"
    n_out=$(PATH="$vp" HOME="$kp_root" CLAUDE_SETTINGS_PATH="$s" "$BASH_BIN" "$HOOKS_DIR/install.sh" 2>&1); n_rc=$?
    n_dr=$(PATH="$vp" CLAUDE_SETTINGS_PATH="$s" HOME="$kp_root" "$BASH_BIN" "$HOOKS_DIR/doctor.sh" 2>&1); n_drc=$?
    if [ "$n_rc" = 0 ] && grep -qF 'npx ccusage statusline' "$s" && ! grep -qF "$HOOKS_DIR/statusline.sh" "$s" \
       && printf '%s\n' "$n_out" | grep -qxF "KEPT: statusLine → npx ccusage statusline (registered elsewhere; re-run with --force to point it at this clone)" \
       && [ "$n_drc" = 0 ] && printf '%s\n' "$n_dr" | grep -qF "OK   KEPT: statusLine → npx ccusage statusline"; then
      pass "[$variant] statusLine without a file path stays, KEPT line printed; doctor rc 0 names the command"
    else
      fail "[$variant] a path-less foreign statusLine was replaced or not reported (rc=$n_rc, doctor rc=$n_drc)" "$n_out | $n_dr"
    fi
    n2_out=$(PATH="$vp" HOME="$kp_root" CLAUDE_SETTINGS_PATH="$s" "$BASH_BIN" "$HOOKS_DIR/install.sh" --force 2>&1); n2_rc=$?
    if [ "$n2_rc" = 0 ] && ! printf '%s' "$n2_out" | grep -q '^KEPT' && ! grep -qF 'npx ccusage' "$s" \
       && grep -qF "$HOOKS_DIR/statusline.sh" "$s"; then
      pass "[$variant] --force replaces a path-less statusLine with this clone's"
    else
      fail "[$variant] --force did not repoint a path-less statusLine (rc=$n2_rc)" "$n2_out"
    fi
    # 4b2) words with a "/" that are not file paths (scoped npm package, sed
    #      expression in a pipeline) are a command, not a path -> KEPT as well.
    #      $HOME/... and ${HOME}/... are paths: expanded, then -f decides.
    mkdir -p "$kp_root/homedir"; printf '#!/bin/bash\nexit 0\n' > "$kp_root/homedir/ext-status.sh"
    while IFS='~' read -r label cmd verdict; do
      s="$kp_root/p-$variant-$label.json"
      python3 -c 'import json,sys; json.dump({"statusLine":{"type":"command","command":sys.argv[1]}}, open(sys.argv[2],"w"))' "$cmd" "$s"
      p_out=$(PATH="$vp" HOME="$kp_root" CLAUDE_SETTINGS_PATH="$s" "$BASH_BIN" "$HOOKS_DIR/install.sh" 2>&1); p_rc=$?
      if [ "$verdict" = kept ]; then
        if [ "$p_rc" = 0 ] && printf '%s\n' "$p_out" | grep -qF "KEPT: statusLine" && ! grep -qF "$HOOKS_DIR/statusline.sh" "$s"; then
          pass "[$variant] statusLine '$label' ($cmd) is kept"
        else fail "[$variant] statusLine '$label' was replaced (rc=$p_rc)" "$p_out"; fi
      else
        if [ "$p_rc" = 0 ] && ! printf '%s\n' "$p_out" | grep -qF "KEPT: statusLine" && grep -qF "$HOOKS_DIR/statusline.sh" "$s"; then
          pass "[$variant] statusLine '$label' ($cmd) is repaired to this clone"
        else fail "[$variant] statusLine '$label' was kept (rc=$p_rc)" "$p_out"; fi
      fi
    done <<LIST
scoped~npx -y @owloops/claude-powerline@latest~kept
pipeline~jq -r .model.display_name | sed s/a/b/~kept
homevar~bash \$HOME/homedir/ext-status.sh~kept
homebrace~bash \${HOME}/homedir/ext-status.sh~kept
homegone~bash \$HOME/homedir/gone-status.sh~ours
LIST
    # 4c) a statusLine on a missing file (any name) -> ours.
    s="$kp_root/slgone-$variant.json"
    printf '{"statusLine":{"type":"command","command":"bash %s/gone/my-status.sh"}}' "$kp_root" > "$s"
    m_out=$(PATH="$vp" HOME="$kp_root" CLAUDE_SETTINGS_PATH="$s" "$BASH_BIN" "$HOOKS_DIR/install.sh" 2>&1); m_rc=$?
    if [ "$m_rc" = 0 ] && ! printf '%s' "$m_out" | grep -q '^KEPT: statusLine' && grep -qF "$HOOKS_DIR/statusline.sh" "$s"; then
      pass "[$variant] statusLine on a missing file -> repaired to this clone"
    else
      fail "[$variant] a statusLine on a missing file was kept (rc=$m_rc)" "$m_out"
    fi
  done
  # 5) doctor weighs every matching registration, not the first: a dead
  #    entry in front of ours must not turn a working install into FAIL.
  s="$kp_root/doctor-order.json"
  CLAUDE_SETTINGS_PATH="$s" HOME="$kp_root" "$BASH_BIN" "$HOOKS_DIR/install.sh" >/dev/null 2>&1
  python3 - "$s" "$kp_root/gone" <<'PYEOF'
import json, sys
p, gone = sys.argv[1:3]
d = json.load(open(p, encoding="utf-8"))
d["hooks"]["UserPromptSubmit"].insert(0, {"matcher": "*", "hooks": [{"type": "command", "command": "bash %s/context-guard.sh" % gone}]})
json.dump(d, open(p, "w", encoding="utf-8"))
PYEOF
  do_out=$(CLAUDE_SETTINGS_PATH="$s" HOME="$kp_root" "$BASH_BIN" "$HOOKS_DIR/doctor.sh" 2>&1); do_rc=$?
  if [ "$do_rc" = 0 ] && printf '%s\n' "$do_out" | grep -qxF "OK   UserPromptSubmit points at our context-guard.sh"; then
    pass "doctor.sh: a dead registration in front of ours does not hide it (OK, rc 0)"
  else
    fail "doctor.sh judged by the first registration only (rc=$do_rc)" "$do_out"
  fi
  # 6) unknown flag -> rc 2, settings untouched.
  s="$kp_root/flag.json"; kept_settings "$s" "$kp_foreign"; cp "$s" "$s.orig"
  CLAUDE_SETTINGS_PATH="$s" HOME="$kp_root" "$BASH_BIN" "$HOOKS_DIR/install.sh" --frce >/dev/null 2>&1; u_rc=$?
  if [ "$u_rc" = 2 ] && cmp -s "$s" "$s.orig"; then
    pass "unknown flag (--frce) -> rc 2, settings.json untouched"
  else
    fail "unknown flag was not refused (rc=$u_rc)"
  fi
else
  echo "SKIP  python3 not available — install.sh needs it anyway"
fi

# ===========================================================================
group "doctor.sh on a single-line (minified) settings.json"
# ===========================================================================
sandbox2="$(mktempdir)"
settings2="$sandbox2/settings.json"
CLAUDE_SETTINGS_PATH="$settings2" "$BASH_BIN" "$HOOKS_DIR/install.sh" >/dev/null 2>&1
if command -v python3 >/dev/null 2>&1; then
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); open(sys.argv[1],'w').write(json.dumps(d))" "$settings2"
  home2="$(mktempdir)"
  doctor_out=$(CLAUDE_SETTINGS_PATH="$settings2" HOME="$home2" "$BASH_BIN" "$HOOKS_DIR/doctor.sh" 2>&1); doctor_rc=$?
  echo "$doctor_out"
  if [ "$doctor_rc" = 0 ] && ! printf '%s' "$doctor_out" | grep -q '^FAIL'; then
    pass "doctor.sh on single-line settings.json -> all OK, rc=0"
  else
    fail "doctor.sh on single-line settings.json -> unexpected FAIL/rc=$doctor_rc" "$doctor_out"
  fi
else
  echo "SKIP  python3 not available — cannot minify settings.json to one line"
fi

# ===========================================================================
group "Negative control 1/2: a syntax error MUST turn the bash -n section red"
# ===========================================================================
mut1="$(mktempdir)"
cp -R "$ROOT/hooks" "$ROOT/tests" "$mut1/"
printf 'if [ 1 = 1 ' >> "$mut1/hooks/install.sh"   # unterminated [ ] / if -> guaranteed syntax error
mut_out=$(bash_n_sweep "$mut1" 2>&1); mut_rc=$?
if [ "$mut_rc" != 0 ] && printf '%s' "$mut_out" | grep -q 'install.sh'; then
  pass "mutated copy (broken hooks/install.sh) -> bash -n correctly reports it broken"
else
  fail "mutated copy did NOT turn bash -n red — negative control is not sensitive" "$mut_out"
fi

# ===========================================================================
group "Negative control 2/2: a mutated default threshold MUST turn threshold-parity.sh red"
# ===========================================================================
mut2="$(mktempdir)"
cp -R "$ROOT/hooks" "$ROOT/tests" "$mut2/"
# Same mutation T-014 used to prove this suite isn't always-green: statusline's
# z1 default only (40 -> 45), guard's default left untouched on purpose.
# Since T-164 the defaults are 40/60/75, so the mutant must use a value that is
# NOT a default threshold (45), and the sed anchor must be checked: a no-match
# sed is a silent no-op that would make this control meaningless.
sed -i.bak 's/local z1=40 z2=60/local z1=45 z2=60/' "$mut2/hooks/statusline.sh" && rm -f "$mut2/hooks/statusline.sh.bak"
grep -q 'local z1=45 z2=60' "$mut2/hooks/statusline.sh" || fail "negative control 2/2: mutation anchor 'local z1=40 z2=60' not found in statusline.sh — control would be a no-op"
mut_tp_out=$("$BASH_BIN" "$mut2/tests/threshold-parity.sh" 2>&1); mut_tp_rc=$?
if [ "$mut_tp_rc" != 0 ] && printf '%s' "$mut_tp_out" | grep -q '^RESULT: RED$'; then
  n_fail=$(printf '%s' "$mut_tp_out" | grep -oE '^TOTAL: [0-9]+/[0-9]+')
  pass "mutated copy (statusline z1=45, guard unchanged) -> threshold-parity.sh correctly reports RED ($n_fail)"
else
  fail "mutated copy did NOT turn threshold-parity.sh red — negative control is not sensitive" "$mut_tp_out"
fi

# ===========================================================================
group "QA 2.0.0 installer: R1 (group neighbours), R2 (quote in the path), Y1 (no python3), Y2 (older clone)"
# ===========================================================================
# clone_copy DIR — a copy of this distribution's install surface (what a clone holds).
clone_copy() { mkdir -p "$1"; cp -R "$ROOT/hooks" "$ROOT/skills" "$ROOT/install.sh" "$ROOT/.claude-plugin" "$1/"; }
if command -v python3 >/dev/null 2>&1; then
  qa_root="$(mktempdir)"; qa_root="$(cd "$qa_root" && pwd)"   # TMPDIR may end in "/": normalise like install.sh does
  # R2: a clone under "Mike's tools/папка с пробелом" — every registered command runs (rc 0), doctor all OK.
  qa_c="$qa_root/Mike's tools/папка с пробелом"; clone_copy "$qa_c"; mkdir -p "$qa_root/h"
  printf '{}' > "$qa_root/r2.json"
  r2_out=$(HOME="$qa_root/h" CLAUDE_SETTINGS_PATH="$qa_root/r2.json" "$BASH_BIN" "$qa_c/install.sh" 2>&1); r2_rc=$?
  r2_bad=""
  for evt in UserPromptSubmit PostToolUse SessionStart PreCompact; do
    cmd=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["hooks"][sys.argv[2]][0]["hooks"][0]["command"])' "$qa_root/r2.json" "$evt")
    for sh_bin in /bin/sh /bin/dash; do
      [ -x "$sh_bin" ] || continue
      printf '{}' | HOME="$qa_root/h" "$sh_bin" -c "$cmd" >/dev/null 2>&1 || r2_bad="$r2_bad $evt($sh_bin rc=$?)"
    done
  done
  if [ "$r2_rc" = 0 ] && [ -z "$r2_bad" ] && ! printf '%s' "$r2_out" | grep -q '^FAIL'; then
    pass "R2: clone path with a quote, a space and Cyrillic -> install rc 0, doctor without FAIL, every hook command rc 0 under sh/dash"
  else
    fail "R2: quote in the clone path broke the registration (rc=$r2_rc)" "bad:$r2_bad | $(printf '%s' "$r2_out" | grep '^FAIL' | head -3)"
  fi
  # R1: a foreign command in the same group as ours and a narrowed matcher survive a re-install (jq and python merges).
  if PATH="$FULL_PATH" command -v jq >/dev/null 2>&1; then mkminpath "$qa_root/p-jq" cp python3 jq; fi
  mkminpath "$qa_root/p-nojq" cp python3
  for variant in jq nojq; do
    vp="$qa_root/p-$variant"
    [ "$variant" = jq ] && [ ! -e "$vp/jq" ] && { echo "SKIP  jq not installed — R1 jq merge not exercised"; continue; }
    s="$qa_root/r1-$variant.json"; printf '{}' > "$s"
    PATH="$vp" HOME="$qa_root/h" CLAUDE_SETTINGS_PATH="$s" "$BASH_BIN" "$HOOKS_DIR/install.sh" >/dev/null 2>&1
    python3 - "$s" <<'PYEOF2'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
g = d["hooks"]["PostToolUse"][0]; g["matcher"] = "Bash|Edit|Write"
g["hooks"].append({"type": "command", "command": "/usr/bin/true # my-audit-hook"})
d["hooks"]["UserPromptSubmit"].append({"matcher": "x", "hooks": [{"type": "command", "command": "echo keep-me"}, {"type": "command", "command": "bash /gone/old/context-guard.sh"}]})
json.dump(d, open(p, "w"))
PYEOF2
    PATH="$vp" HOME="$qa_root/h" CLAUDE_SETTINGS_PATH="$s" "$BASH_BIN" "$HOOKS_DIR/install.sh" >/dev/null 2>&1; r1_rc=$?
    cp "$s" "$s.1"; PATH="$vp" HOME="$qa_root/h" CLAUDE_SETTINGS_PATH="$s" "$BASH_BIN" "$HOOKS_DIR/install.sh" >/dev/null 2>&1
    r1_rep=$(python3 - "$s" "$HOOKS_DIR" <<'PYEOF2'
import json, sys
d = json.load(open(sys.argv[1])); here = sys.argv[2]
def sig(g): return (g.get("matcher"), ["OURS" if here + "/context-guard.sh" in h["command"] else h["command"] for h in g["hooks"]])
print(sig(d["hooks"]["PostToolUse"][0]), len(d["hooks"]["PostToolUse"]), [sig(g) for g in d["hooks"]["UserPromptSubmit"]])
PYEOF2
)
    want="('Bash|Edit|Write', ['OURS', '/usr/bin/true # my-audit-hook']) 1 [('*', ['OURS']), ('x', ['echo keep-me'])]"
    if [ "$r1_rc" = 0 ] && [ "$r1_rep" = "$want" ] && cmp -s "$s" "$s.1"; then
      pass "[$variant] R1: only our command replaced in place — neighbour hook and matcher kept, our duplicate in another group removed, idempotent"
    else
      fail "[$variant] R1: the group around our command was not preserved (rc=$r1_rc)" "$r1_rep"
    fi
  done
  # Y1: jq but no python3 -> the installer refuses BEFORE any write (no skills copied, settings untouched).
  mkminpath "$qa_root/p-y1" cp jq
  printf '{"model":"opus"}' > "$qa_root/y1.json"; cp "$qa_root/y1.json" "$qa_root/y1.orig"; mkdir -p "$qa_root/hy1"
  y1_out=$(PATH="$qa_root/p-y1" HOME="$qa_root/hy1" CLAUDE_SETTINGS_PATH="$qa_root/y1.json" "$BASH_BIN" "$ROOT/install.sh" 2>&1); y1_rc=$?
  y1h_out=$(PATH="$qa_root/p-y1" HOME="$qa_root/hy1" CLAUDE_SETTINGS_PATH="$qa_root/y1-missing.json" "$BASH_BIN" "$HOOKS_DIR/install.sh" 2>&1); y1h_rc=$?
  if [ "$y1_rc" = 1 ] && printf '%s' "$y1_out" | grep -q 'python3 is required' && ! printf '%s' "$y1_out" | grep -q 'invalid JSON' \
     && [ ! -e "$qa_root/hy1/.claude/skills" ] && cmp -s "$qa_root/y1.json" "$qa_root/y1.orig" && ! ls "$qa_root"/y1.json.bak-* >/dev/null 2>&1 \
     && [ "$y1h_rc" = 1 ] && printf '%s' "$y1h_out" | grep -q 'python3 is required' && [ ! -e "$qa_root/y1-missing.json" ]; then
    pass "Y1: jq without python3 -> «python3 is required», rc 1, no skills copied, settings untouched, no backup, no file created"
  else
    fail "Y1: install without python3 was not refused cleanly (rc=$y1_rc / $y1h_rc)" "$y1_out | $y1h_out"
  fi
  # Y2: registrations of an OLDER pf-handoff clone are moved here (MOVED x5), doctor warns before; a canon-like copy without plugin.json stays KEPT.
  qa_old="$qa_root/old-clone"; clone_copy "$qa_old"
  s="$qa_root/y2.json"; printf '{}' > "$s"
  HOME="$qa_root/h" CLAUDE_SETTINGS_PATH="$s" "$BASH_BIN" "$qa_old/hooks/install.sh" >/dev/null 2>&1
  y2_dr=$(HOME="$qa_root/h" CLAUDE_SETTINGS_PATH="$s" "$BASH_BIN" "$HOOKS_DIR/doctor.sh" 2>&1); y2_drc=$?
  y2_out=$(HOME="$qa_root/h" CLAUDE_SETTINGS_PATH="$s" "$BASH_BIN" "$HOOKS_DIR/install.sh" 2>&1); y2_rc=$?
  y2_dr2=$(HOME="$qa_root/h" CLAUDE_SETTINGS_PATH="$s" "$BASH_BIN" "$HOOKS_DIR/doctor.sh" 2>&1); y2_drc2=$?
  if [ "$y2_drc" = 0 ] && [ "$(printf '%s\n' "$y2_dr" | grep -c '^WARN .*points at another pf-handoff clone')" = 5 ] \
     && [ "$y2_rc" = 0 ] && [ "$(printf '%s\n' "$y2_out" | grep '^MOVED: ' | grep -F "$qa_old/hooks/" | grep -cF "→ $HOOKS_DIR/")" = 5 ] \
     && ! grep -qF "$qa_old" "$s" && [ "$y2_drc2" = 0 ] && ! printf '%s' "$y2_dr2" | grep -qE '^(WARN|FAIL)'; then
    pass "Y2: older clone -> doctor WARN x5 (rc 0), install MOVED x5, everything points here, doctor clean afterwards"
  else
    fail "Y2: older clone not moved or not reported" "drc=$y2_drc rc=$y2_rc drc2=$y2_drc2 warn=$(printf '%s\n' "$y2_dr" | grep -c '^WARN') moved=$(printf '%s\n' "$y2_out" | grep -c '^MOVED') left=$(grep -cF "$qa_old" "$s") after=$(printf '%s' "$y2_dr2" | grep -E '^(WARN|FAIL)' | head -2)"
  fi
  # A v1.10.0-style clone (no .claude-plugin/, the shipped skills/pf-handoff/SKILL.md names it) is ours too.
  qa_v110="$qa_root/v110-clone"; clone_copy "$qa_v110"; rm -rf "$qa_v110/.claude-plugin"
  s="$qa_root/y2v.json"; printf '{}' > "$s"
  HOME="$qa_root/h" CLAUDE_SETTINGS_PATH="$s" "$BASH_BIN" "$qa_v110/hooks/install.sh" >/dev/null 2>&1
  y2v_out=$(HOME="$qa_root/h" CLAUDE_SETTINGS_PATH="$s" "$BASH_BIN" "$HOOKS_DIR/install.sh" 2>&1)
  if [ "$(printf '%s\n' "$y2v_out" | grep -c '^MOVED: ')" = 5 ] && ! grep -qF "$qa_v110" "$s"; then
    pass "Y2: a v1.10.0-style clone (no plugin.json, skills/pf-handoff/SKILL.md) is moved as well"
  else
    fail "Y2: v1.10.0-style clone not moved" "$y2v_out"
  fi
  # Control: the workshop canon layout (<workshop>/context-hooks/, no install.sh, no skills/ beside it) stays KEPT.
  qa_canon="$qa_root/workshop/context-hooks"; mkdir -p "$qa_canon"; cp "$HOOKS_DIR"/*.sh "$qa_canon/"
  s="$qa_root/y2c.json"; printf '{}' > "$s"
  HOME="$qa_root/h" CLAUDE_SETTINGS_PATH="$s" "$BASH_BIN" "$qa_canon/install.sh" >/dev/null 2>&1
  y2c_out=$(HOME="$qa_root/h" CLAUDE_SETTINGS_PATH="$s" "$BASH_BIN" "$HOOKS_DIR/install.sh" 2>&1)
  if [ "$(printf '%s\n' "$y2c_out" | grep -c '^KEPT: ')" = 5 ] && ! printf '%s' "$y2c_out" | grep -q '^MOVED'; then
    pass "Y2 control: the workshop canon layout (context-hooks/, no clone markers) stays KEPT"
  else
    fail "Y2 control: canon-like copy was moved" "$y2c_out"
  fi
  # N4: another tool's hook that merely shares our file name (precompact.sh,
  # none of our scripts next to it) stays KEPT, but loudly: `WARN: KEPT:`
  # from the installer and WARN (not OK) from doctor; --force names it in a
  # REPLACED line before replacing it.
  qa_oth="$qa_root/other/hooks"; mkdir -p "$qa_oth"; printf '#!/bin/bash\nexit 0\n' > "$qa_oth/precompact.sh"; chmod +x "$qa_oth/precompact.sh"
  s="$qa_root/n4.json"
  printf '{"hooks":{"PreCompact":[{"hooks":[{"type":"command","command":"bash %s/precompact.sh"}]}]}}' "$qa_oth" > "$s"
  n4_out=$(HOME="$qa_root/h" CLAUDE_SETTINGS_PATH="$s" "$BASH_BIN" "$HOOKS_DIR/install.sh" 2>&1); n4_rc=$?
  n4_dr=$(HOME="$qa_root/h" CLAUDE_SETTINGS_PATH="$s" "$BASH_BIN" "$HOOKS_DIR/doctor.sh" 2>&1)
  if [ "$n4_rc" = 0 ] && printf '%s\n' "$n4_out" | grep -qF "WARN: KEPT: PreCompact → $qa_oth/precompact.sh is not a pf-handoff hook" \
     && printf '%s\n' "$n4_out" | grep -qF "our PreCompact hook is NOT installed" && ! printf '%s\n' "$n4_out" | grep -q '^KEPT: PreCompact' \
     && grep -qF "$qa_oth/precompact.sh" "$s" && ! grep -qF "$HOOKS_DIR/precompact.sh" "$s" \
     && printf '%s\n' "$n4_dr" | grep -qF "WARN KEPT: PreCompact → $qa_oth/precompact.sh is not a pf-handoff hook" \
     && ! printf '%s\n' "$n4_dr" | grep -q '^OK   KEPT: PreCompact'; then
    pass "N4: a foreign same-name hook stays, installer prints WARN: KEPT (our hook NOT installed), doctor WARN, not OK"
  else
    fail "N4: a foreign same-name hook was kept silently" "rc=$n4_rc out=$n4_out | doctor=$(printf '%s' "$n4_dr" | grep PreCompact)"
  fi
  n4f_out=$(HOME="$qa_root/h" CLAUDE_SETTINGS_PATH="$s" "$BASH_BIN" "$HOOKS_DIR/install.sh" --force 2>&1); n4f_rc=$?
  if [ "$n4f_rc" = 0 ] && printf '%s\n' "$n4f_out" | grep -qxF "REPLACED: PreCompact bash $qa_oth/precompact.sh → $HOOKS_DIR/precompact.sh" \
     && ! grep -qF "$qa_oth" "$s" && grep -qF "$HOOKS_DIR/precompact.sh" "$s"; then
    pass "N4: --force prints «REPLACED: PreCompact <old command> → <ours>» before replacing the foreign hook"
  else
    fail "N4: --force replaced the foreign hook without a REPLACED line" "rc=$n4f_rc out=$n4f_out"
  fi
  # N4 step 2 (fix round 1): an older v1.10.0-style clone plus a foreign
  # sessionstart.sh in the same event — all five registrations of the old
  # clone are MOVED here (SessionStart too), the foreign hook stays next to
  # ours with WARN: KEPT; doctor is then clean for SessionStart (no looping
  # «install.sh moves it here»); a second run changes nothing.
  qa_old2="$qa_root/old-clone2"; clone_copy "$qa_old2"; rm -rf "$qa_old2/.claude-plugin"
  s="$qa_root/n4b.json"; printf '{}' > "$s"
  HOME="$qa_root/h" CLAUDE_SETTINGS_PATH="$s" "$BASH_BIN" "$qa_old2/hooks/install.sh" >/dev/null 2>&1
  printf '#!/bin/bash\nexit 0\n' > "$qa_oth/sessionstart.sh"; chmod +x "$qa_oth/sessionstart.sh"
  python3 - "$s" "$qa_oth/sessionstart.sh" <<'PYEOF2'
import json, sys
d = json.load(open(sys.argv[1])); d["hooks"]["SessionStart"][0]["hooks"].append({"type": "command", "command": "bash " + sys.argv[2]})
json.dump(d, open(sys.argv[1], "w"))
PYEOF2
  n4b_out=$(HOME="$qa_root/h" CLAUDE_SETTINGS_PATH="$s" "$BASH_BIN" "$HOOKS_DIR/install.sh" 2>&1)
  n4b_rep=$(reg_report "$s")
  n4b_dr=$(HOME="$qa_root/h" CLAUDE_SETTINGS_PATH="$s" "$BASH_BIN" "$HOOKS_DIR/doctor.sh" 2>&1)
  cp "$s" "$s.1"; n4b_out2=$(HOME="$qa_root/h" CLAUDE_SETTINGS_PATH="$s" "$BASH_BIN" "$HOOKS_DIR/install.sh" 2>&1)
  if [ "$(printf '%s\n' "$n4b_out" | grep -c '^MOVED: ')" = 5 ] \
     && printf '%s\n' "$n4b_out" | grep -qF "MOVED: SessionStart $qa_old2/hooks/sessionstart.sh → $HOOKS_DIR/sessionstart.sh" \
     && printf '%s\n' "$n4b_out" | grep -qF "WARN: KEPT: SessionStart → $qa_oth/sessionstart.sh is not a pf-handoff hook" \
     && printf '%s\n' "$n4b_rep" | grep -qxF "SessionStart=$HOOKS_DIR/sessionstart.sh,$qa_oth/sessionstart.sh" \
     && ! grep -qF "$qa_old2" "$s" \
     && printf '%s\n' "$n4b_dr" | grep -qF "OK   SessionStart points at our sessionstart.sh" \
     && ! printf '%s\n' "$n4b_dr" | grep -q 'another pf-handoff clone' \
     && cmp -s "$s" "$s.1" && ! printf '%s\n' "$n4b_out2" | grep -q '^MOVED'; then
    pass "N4: v1.10.0 clone + foreign sessionstart.sh -> MOVED x5 (SessionStart too), foreign stays next to ours (WARN: KEPT), doctor OK, re-run idempotent"
  else
    fail "N4: older clone left in SessionStart next to a foreign same-name hook" "out=$n4b_out | rep=$n4b_rep | dr=$(printf '%s' "$n4b_dr" | grep SessionStart) | out2=$n4b_out2"
  fi
else
  echo "SKIP  python3 not available — the installer requires it"
fi

# ===========================================================================
group "private-word stop-list (PF_PRIVATE_WORDS, owner-only; silent without it)"
# ===========================================================================
# The list itself lives outside this repository (the author's workshop) and
# never ships. Without PF_PRIVATE_WORDS (a friend's machine) the group is skipped.
pw_scan() { # pw_scan ROOT WORDS-FILE -> matching file names / files, one per line
  local root="$1" words; words="$(mktempdir)/w"
  { grep -v '^[[:space:]]*#' "$2" || true; } | sed 's/[[:space:]]*$//' | { grep -v '^$' || true; } > "$words"
  [ -s "$words" ] || { echo "EMPTY-LIST"; return 0; }
  (cd "$root" && find . \( -name .git -o -name .claude -o -name .agents -o -path ./evals/results \) -prune -o -type f -print \
     | { grep -iF -f "$words" || true; } | sed 's/^/name: /'
   cd "$root" && find . \( -name .git -o -name .claude -o -name .agents -o -path ./evals/results \) -prune -o -type f -print0 \
     | xargs -0 grep -IilF -f "$words" 2>/dev/null | sed 's/^/text: /')
}
if [ -n "${PF_PRIVATE_WORDS:-}" ] && [ -r "$PF_PRIVATE_WORDS" ]; then
  pw_out=$(pw_scan "$ROOT" "$PF_PRIVATE_WORDS")
  [ -z "$pw_out" ] && pass "no private word in the distribution tree" || fail "private words found in the distribution tree" "$pw_out"
  # Negative control: one word of the list planted into a copy -> found.
  pw_mut="$(mktempdir)"; cp -R "$ROOT/README.md" "$ROOT/docs" "$pw_mut/"
  pw_word=$({ grep -v '^[[:space:]]*#' "$PF_PRIVATE_WORDS" || true; } | sed 's/[[:space:]]*$//' | { grep -v '^$' || true; } | head -1)
  printf '\nplanted: %s\n' "$pw_word" >> "$pw_mut/README.md"
  pw_mout=$(pw_scan "$pw_mut" "$PF_PRIVATE_WORDS")
  printf '%s' "$pw_mout" | grep -qx 'text: ./README.md' && pass "negative control: a planted word in a copy of README.md is found" || fail "negative control: planted word not found" "$pw_mout"
else
  echo "SKIP  PF_PRIVATE_WORDS not set — the private-word stop-list is the author's (not shipped)"
fi

# ===========================================================================
group "No real network calls, no undeclared external processes in this suite"
# ===========================================================================
# curl/wget anywhere under tests/ would be a smell for a suite that must
# never touch the network. Excludes run.sh itself: this very check's own
# pattern text would otherwise self-match and always fail.
net_hits=$(grep -rnE '\bcurl\b|\bwget\b' "$TESTS_DIR" --include='*.sh' 2>/dev/null | grep -v '^[^:]*/run\.sh:' || true)
if [ -z "$net_hits" ]; then
  pass "grep -rnE 'curl|wget' tests/*.sh (excluding run.sh itself) -> no matches"
else
  fail "found a curl/wget reference under tests/" "$net_hits"
fi

echo
echo "=== SUMMARY ==="
if [ -n "$CURRENT_GROUP" ]; then
  GROUP_SUMMARY+=("$CURRENT_GROUP: $GROUP_PASS/$((GROUP_PASS + GROUP_FAIL))")
fi
for line in "${GROUP_SUMMARY[@]+"${GROUP_SUMMARY[@]}"}"; do echo "$line"; done
echo "TOTAL: $PASS/$((PASS + FAIL))"
if [ "$FAIL" -gt 0 ]; then
  echo
  echo "Failed:"
  for l in "${FAIL_LABELS[@]+"${FAIL_LABELS[@]}"}"; do echo "  - $l"; done
fi
if [ "$FAIL" -eq 0 ]; then
  echo "RESULT: GREEN"
  exit 0
else
  echo "RESULT: RED"
  exit 1
fi
