#!/usr/bin/env bash
# threshold-parity.sh — regression suite for statusline.sh / context-guard.sh
# threshold handling (T-014, F-20). One command: `bash tests/threshold-parity.sh`.
#
# Two things are under test:
#  1. Parity: both hooks derive the SAME colour/zone boundary from the SAME
#     project `.agents/context-budget.json` — this is the methodology from
#     journal 2026-08-12 06:00 ("живой statusline.sh --preview против эталона
#     guard на 9 кейсах"), reconstructed here as an automated table (that run
#     found 5 discrepancies, since fixed; this file guards the regression).
#     `--preview` hardcodes used_percentage=41 and reads its config from
#     $PWD, so the CONFIG is the lever across the 9 cases, not the percentage.
#  2. The `PF_EFFECTIVE_HOME` contract (F-20): both hooks must survive an
#     absent $HOME (falling back to $TMPDIR) without crashing and while still
#     persisting session state — proven as one chain (statusline writes state
#     under the fallback home, guard reads that same state back).
#
# Bash 3.2 compatible (macOS system bash floor — same constraint as pf-do's
# own test harness): no associative arrays, no ${var,,}, no mapfile.
# Self-contained on purpose — does not source pf-do's tests/lib.sh, a
# different skill's private test fixture.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$(cd "$TESTS_DIR/../hooks" && pwd)"
STATUSLINE="$HOOKS_DIR/statusline.sh"
GUARD="$HOOKS_DIR/context-guard.sh"
BASH_BIN="$(command -v bash)"

[ -f "$STATUSLINE" ] || { echo "cannot find statusline.sh at $STATUSLINE"; exit 90; }
[ -f "$GUARD" ] || { echo "cannot find context-guard.sh at $GUARD"; exit 90; }

# --- tiny table-driven harness (style matches pf-do/scripts/tests/lib.sh,
# copied rather than sourced — see header note) --------------------------
PASS=0
FAIL=0
FAIL_LABELS=()
CURRENT_GROUP=""
GROUP_PASS=0
GROUP_FAIL=0
GROUP_SUMMARY=()
CLEANUP_DIRS=()

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
finish() {
  if [ -n "$CURRENT_GROUP" ]; then
    GROUP_SUMMARY+=("$CURRENT_GROUP: $GROUP_PASS/$((GROUP_PASS + GROUP_FAIL))")
  fi
  echo; echo "=== SUMMARY ==="
  local line
  for line in "${GROUP_SUMMARY[@]+"${GROUP_SUMMARY[@]}"}"; do echo "$line"; done
  echo "TOTAL: $PASS/$((PASS + FAIL))"
  if [ "$FAIL" -gt 0 ]; then
    echo; echo "Failed:"
    local l
    for l in "${FAIL_LABELS[@]+"${FAIL_LABELS[@]}"}"; do echo "  - $l"; done
  fi
  local d
  for d in "${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}"; do [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"; done
  if [ "$FAIL" -eq 0 ]; then echo "RESULT: GREEN"; return 0; else echo "RESULT: RED"; return 1; fi
}

# Portable form: GNU mktemp (Linux, incl. ubuntu-latest) rejects a bare
# `-t <prefix>` ("too few X's in template"); BSD mktemp (macOS) accepts it.
# An explicit template with X's works identically on both (verified T-016).
mktempdir() { local d; d=$(mktemp -d "${TMPDIR:-/tmp}/thr-parity.XXXXXXXX"); CLEANUP_DIRS+=("$d"); printf '%s' "$d"; }

echo "threshold-parity.sh — context-hooks regression suite"
echo "statusline: $STATUSLINE"
echo "guard:      $GUARD"
echo "bash:       $BASH_BIN ($("$BASH_BIN" --version | head -1))"

# --- statusline zone via --preview (pct is always 41; config is the lever) -
# Reads only the "Context:" line and looks at which zone colour precedes the
# bar (C_GRN/C_YLW/C_RED — see statusline.sh). PF_STATUSLINE_CONFIG is
# pinned to a nonexistent path so an operator's real ~/.config/pf-handoff/
# statusline.json (colours off, custom layout, ...) can never leak into the
# test. Run from a NON-git temp dir on purpose: seg_branch() also colours
# its +N/-N counters green/red, which would confound the zone read.
sl_zone() {
  local proj="$1" out ctxline
  out=$(cd "$proj" && PF_STATUSLINE_CONFIG=/nonexistent-thr-parity-cfg.json "$BASH_BIN" "$STATUSLINE" --preview 2>/dev/null)
  ctxline=$(printf '%s\n' "$out" | grep 'Context:')
  case "$ctxline" in
    *$'\033[31m'*) echo red ;;
    *$'\033[33m'*) echo yellow ;;
    *$'\033[32m'*) echo green ;;
    *) echo unknown ;;
  esac
}

# --- guard zone via a seeded state file (pct=41, announced=0) --------------
# UserPromptSubmit/PostToolUse never carry pct directly; the real hook reads
# it from the state file statusline.sh maintains. Seeding it here isolates
# the threshold comparison from the transcript-parsing fallback entirely.
# Bucketing: THRESH_Z2 and THRESH_Z3 both count as "red" — statusline only
# ever renders two boundaries (z1/z2), so its red covers guard's t2 *and* t3
# (see the statusline.sh comment on why it deliberately ignores the third
# threshold). THRESH_Z1 -> "yellow"; no directive -> "green".
guard_zone() {
  local proj="$1" home="$2" pct="$3" sid out now
  sid="parity-$$-$RANDOM"
  mkdir -p "$home/.claude/context-state"
  now=$(date +%s)
  printf '{"pct": %s, "window": 200000, "input_tokens": 82000, "updated": %s, "announced": 0}' \
    "$pct" "$now" > "$home/.claude/context-state/$sid.json"
  out=$(printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","transcript_path":"/nonexistent.jsonl","cwd":"%s"}' "$sid" "$proj" \
    | HOME="$home" CLAUDE_SETTINGS_PATH=/nonexistent-thr-parity-settings.json "$BASH_BIN" "$GUARD" 2>/dev/null)
  if printf '%s' "$out" | grep -q 'немедленно полный'; then echo red
  elif printf '%s' "$out" | grep -q 'M/L-кусков'; then echo red
  elif printf '%s' "$out" | grep -q 'чекпоинт HANDOFF'; then echo yellow
  else echo green
  fi
}

run_case() {
  local name="$1" cfg="$2" expect="$3" proj home sl gd
  proj=$(mktempdir)
  if [ -n "$cfg" ]; then
    mkdir -p "$proj/.agents"
    printf '%s' "$cfg" > "$proj/.agents/context-budget.json"
  fi
  home=$(mktempdir)
  sl=$(sl_zone "$proj")
  gd=$(guard_zone "$proj" "$home" 41)
  if [ "$sl" = "$expect" ] && [ "$gd" = "$expect" ]; then
    pass "$name -> statusline=$sl guard=$gd"
  else
    fail "$name -> statusline=$sl guard=$gd (expected $expect)" "config: ${cfg:-<none>}"
  fi
}

# ===========================================================================
group "Parity at pct=41: 1 default + 3 valid boundary configs"
# ===========================================================================
# Defaults (60/80/90): 41 sits below the first boundary either way.
run_case "no config file (defaults 60/80/90)" "" green
# Custom z1 raised above 41: still green, but on a NON-default boundary.
run_case "valid config, 41 stays green [42,50,60]" '{"thresholds":[42,50,60]}' green
# 41 lands inside [t1,t2): first zone on both sides.
run_case "valid config, 41 is yellow [40,60,80]"   '{"thresholds":[40,60,80]}' yellow
# 41 clears t3 too: guard's most severe zone, statusline's only "red".
run_case "valid config, 41 is red [30,35,40]"      '{"thresholds":[30,35,40]}' red

# ===========================================================================
group "Parity at pct=41: 5 malformed configs (both sides must reject -> defaults -> green)"
# ===========================================================================
# All five use LOW numbers (< 41) on purpose: if either script's validation
# regresses and accepts the malformed value at face value, 41 would land in
# yellow/red and the case fails loudly. A pass here is evidence of rejection,
# not a coincidence of the numbers chosen (see case block above for that).
run_case "embedded space inside one element" '{"thresholds":["20 25",30,35]}' green
run_case "float element"                     '{"thresholds":[20.5,25,30]}'    green
run_case "leading-space string element"      '{"thresholds":[" 20",25,30]}'   green
run_case "non-ascending"                     '{"thresholds":[30,25,20]}'      green
run_case "wrong length (2, not 3)"           '{"thresholds":[20,25]}'         green

# ===========================================================================
group "F-20: env -u HOME — both hooks stay rc=0 and chain through the TMPDIR fallback"
# ===========================================================================
# TMPDIR is pinned to a sandbox so the fallback path is both deterministic
# and verifiable (real $HOME is never touched by this suite in any group).
sandbox=$(mktempdir)
proj=$(mktempdir)
sid="nohome-$$-$RANDOM"
state_file="$sandbox/.claude/context-state/$sid.json"

sl_input=$(printf '{"session_id":"%s","context_window":{"used_percentage":85,"context_window_size":200000,"total_input_tokens":170000},"workspace":{"current_dir":"%s"},"cwd":"%s"}' "$sid" "$proj" "$proj")
sl_out=$(printf '%s' "$sl_input" | env -u HOME TMPDIR="$sandbox" PF_STATUSLINE_CONFIG=/nonexistent-thr-parity-cfg.json "$BASH_BIN" "$STATUSLINE" 2>&1)
sl_rc=$?
if [ "$sl_rc" -eq 0 ] && [ -f "$state_file" ]; then
  pass "statusline.sh env -u HOME TMPDIR=<sandbox>: rc=0, state written to \$TMPDIR fallback"
else
  fail "statusline.sh env -u HOME: rc=$sl_rc, state_file present=$([ -f "$state_file" ] && echo yes || echo no)" "stdout/stderr: $sl_out"
fi

gd_input=$(printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","transcript_path":"/nonexistent.jsonl","cwd":"%s"}' "$sid" "$proj")
gd_out=$(printf '%s' "$gd_input" | env -u HOME TMPDIR="$sandbox" CLAUDE_SETTINGS_PATH=/nonexistent-thr-parity-settings.json "$BASH_BIN" "$GUARD" 2>&1)
gd_rc=$?
announced_after=$(grep -oE '"announced":[[:space:]]*[0-9]+' "$state_file" 2>/dev/null | grep -oE '[0-9]+' | head -1)
if [ "$gd_rc" -eq 0 ] && [ "${announced_after:-0}" = "80" ] && printf '%s' "$gd_out" | grep -q 'M/L-кусков'; then
  pass "context-guard.sh env -u HOME TMPDIR=<sandbox>: rc=0, reads statusline's state, announces zone2 (announced=80)"
else
  fail "context-guard.sh env -u HOME: rc=$gd_rc, announced=${announced_after:-<missing>}" "stdout/stderr: $gd_out"
fi

finish
