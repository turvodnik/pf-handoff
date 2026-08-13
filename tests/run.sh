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
group "hooks never crash: garbage stdin x {jq-only, python3-only, neither} x env -u HOME"
# ===========================================================================
# Three curated PATH variants isolate which JSON reader branch actually ran
# (context-guard.sh and statusline.sh both branch on `command -v jq`) — a dev
# machine with jq installed would otherwise never exercise the python3-only
# branch at all.
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
  for hook in statusline.sh context-guard.sh sessionstart.sh precompact.sh; do
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
# z1 default only (60 -> 40), guard's default left untouched on purpose.
sed -i.bak 's/local z1=60 z2=80/local z1=40 z2=80/' "$mut2/hooks/statusline.sh" && rm -f "$mut2/hooks/statusline.sh.bak"
mut_tp_out=$("$BASH_BIN" "$mut2/tests/threshold-parity.sh" 2>&1); mut_tp_rc=$?
if [ "$mut_tp_rc" != 0 ] && printf '%s' "$mut_tp_out" | grep -q '^RESULT: RED$'; then
  n_fail=$(printf '%s' "$mut_tp_out" | grep -oE '^TOTAL: [0-9]+/[0-9]+')
  pass "mutated copy (statusline z1=40, guard unchanged) -> threshold-parity.sh correctly reports RED ($n_fail)"
else
  fail "mutated copy did NOT turn threshold-parity.sh red — negative control is not sensitive" "$mut_tp_out"
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
