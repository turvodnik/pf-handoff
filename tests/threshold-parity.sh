#!/usr/bin/env bash
# threshold-parity.sh — regression suite for statusline.sh / context-guard.sh
# threshold handling (T-014, F-20). One command: `bash tests/threshold-parity.sh`.
#
# Two things are under test:
#  1. Parity: both hooks derive the SAME colour/zone boundary from the SAME
#     CONTEXT_GUARD_THRESHOLDS value (T-164; default 40/60/75 % of the window,
#     the project file `.agents/context-budget.json` is no longer read) — this is the methodology from
#     journal 2026-08-12 06:00 ("живой statusline.sh --preview против эталона
#     guard на 9 кейсах"), reconstructed here as an automated table (that run
#     found 5 discrepancies, since fixed; this file guards the regression).
#     `--preview` hardcodes used_percentage=41, so the env value is the lever
#     across the cases, not the percentage.
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
  out=$(cd "$proj" && CONTEXT_GUARD_THRESHOLDS="${THR_ENV:-}" PF_STATUSLINE_CONFIG=/nonexistent-thr-parity-cfg.json "$BASH_BIN" "$STATUSLINE" --preview 2>/dev/null)
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
# Optional 4th/5th args seed the token count and window (T-111 budget cases
# need the SAME tokens `--preview` hardcodes: 410000 of 1M).
guard_zone() {
  local proj="$1" home="$2" pct="$3" tokens="${4:-82000}" window="${5:-200000}" sid out now
  sid="parity-$$-$RANDOM"
  mkdir -p "$home/.claude/context-state"
  now=$(date +%s)
  printf '{"pct": %s, "window": %s, "input_tokens": %s, "updated": %s, "announced": 0, "state_version": 2}' \
    "$pct" "$window" "$tokens" "$now" > "$home/.claude/context-state/$sid.json"
  out=$(printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","transcript_path":"/nonexistent.jsonl","cwd":"%s"}' "$sid" "$proj" \
    | HOME="$home" CONTEXT_GUARD_THRESHOLDS="${THR_ENV:-}" CLAUDE_SETTINGS_PATH=/nonexistent-thr-parity-settings.json "$BASH_BIN" "$GUARD" 2>/dev/null)
  if printf '%s' "$out" | grep -q 'финальный pf-handoff'; then echo red
  elif printf '%s' "$out" | grep -q 'новых M/L не начинать'; then echo red
  elif printf '%s' "$out" | grep -q 'короткий чекпоинт HANDOFF'; then echo yellow
  else echo green
  fi
}

run_case() {
  local name="$1" cfg="$2" expect="$3" tokens="${4:-82000}" window="${5:-200000}" proj home sl gd
  proj=$(mktempdir)
  if [ -n "${FILE_CFG:-}" ]; then
    mkdir -p "$proj/.agents"
    printf '%s' "$FILE_CFG" > "$proj/.agents/context-budget.json"
    [ -f "$proj/.agents/context-budget.json" ] || fail "fixture file not written ($name)"
  fi
  home=$(mktempdir)
  THR_ENV="$cfg"
  sl=$(sl_zone "$proj")
  gd=$(guard_zone "$proj" "$home" 41 "$tokens" "$window")
  THR_ENV=""
  if [ "$sl" = "$expect" ] && [ "$gd" = "$expect" ]; then
    pass "$name -> statusline=$sl guard=$gd"
  else
    fail "$name -> statusline=$sl guard=$gd (expected $expect)" "CONTEXT_GUARD_THRESHOLDS: ${cfg:-<unset>}"
  fi
}

# ===========================================================================
group "Parity at pct=41: default 40/60/75 + valid env overrides"
# ===========================================================================
# Defaults (40/60/75): 41 sits in [t1,t2) -> yellow on both sides.
run_case "env unset (defaults 40/60/75)" "" yellow
run_case "env \"42 50 60\": 41 stays green" "42 50 60" green
run_case "env \"40 60 80\": 41 is yellow"   "40 60 80" yellow
run_case "env \"30 35 40\": 41 is red"      "30 35 40" red
run_case "env \"30 50 70\" (spec example): 41 is yellow" "30 50 70" yellow

# ===========================================================================
group "Parity at pct=41: malformed env values (both sides must reject -> defaults -> yellow)"
# ===========================================================================
# All use LOW numbers (< 41) on purpose: if either side accepted the value at
# face value, 41 would land in red (or green for the too-short ones) and the
# case fails loudly; the default reading is yellow.
run_case "non-ascending"            "30 25 20"      yellow
run_case "float element"            "20.5 25 30"    yellow
run_case "signed element"           "+20 25 30"     yellow
run_case "two numbers, not three"   "20 25"         yellow
run_case "four numbers"             "20 25 30 35"   yellow
run_case "letters"                  "a b c"         yellow
run_case "comma-separated"          "20,25,30"      yellow
run_case "t3 over 99"               "20 25 100"     yellow
run_case "zero first element"       "0 5 10"        yellow
# (A UTF-8 BOM case of the file era has no env analogue: dropped with the file.)

# ===========================================================================
group "T-164: a leftover project budget file is NOT read (both sides on the window defaults)"
# ===========================================================================
# `--preview` hardcodes 410 000 tokens of a 1M window (41 %). With the old file
# format, budget 500000 made the guard 82 % (red); now both sides must stay on
# the window default (yellow) whatever the file says.
FILE_CFG='{"budget_tokens":500000}' run_case "budget_tokens 500000 file ignored"                  "" yellow 410000 1000000
FILE_CFG='{"thresholds":[10,20,30]}' run_case "thresholds [10,20,30] file ignored"                 "" yellow 410000 1000000
FILE_CFG='{"thresholds":[40,60,80],"budget_tokens":300000}' run_case "thresholds+budget file ignored" "" yellow 410000 1000000

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
if [ "$gd_rc" -eq 0 ] && [ "${announced_after:-0}" = "75" ] && printf '%s' "$gd_out" | grep -q 'финальный pf-handoff'; then
  pass "context-guard.sh env -u HOME TMPDIR=<sandbox>: rc=0, reads statusline's state, announces zone3 (announced=75)"
else
  fail "context-guard.sh env -u HOME: rc=$gd_rc, announced=${announced_after:-<missing>}" "stdout/stderr: $gd_out"
fi

# ===========================================================================
group "T-031: auto-checkpoint at t2 and the compaction gate in PreCompact"
# ===========================================================================
# The invariant under test is asymmetric on purpose: a snapshot that CANNOT be
# written must be loud and must stop compaction (I-036 — compacting with the
# state lost is worse than not compacting), while an unexpected script fault
# must never block. Both halves are exercised: success and forced failure.
AUTOCKPT="$HOOKS_DIR/autocheckpoint.sh"
PRECOMPACT="$HOOKS_DIR/precompact.sh"

# Failure is forced with chmod 555 on both write targets; as root that is a
# no-op and the two negative cases would silently pass for the wrong reason.
IS_ROOT=0; [ "$(id -u)" = "0" ] && IS_ROOT=1

# Seeds a project + sandbox home, fires the guard at `pct`, echoes the emitted
# additionalContext. Same seeded-state technique as guard_zone() above.
guard_at() {
  local proj="$1" home="$2" pct="$3" sid="$4" now
  mkdir -p "$home/.claude/context-state"
  now=$(date +%s)
  printf '{"pct": %s, "window": 1000000, "input_tokens": 800000, "updated": %s, "announced": 0, "state_version": 2}' \
    "$pct" "$now" > "$home/.claude/context-state/$sid.json"
  printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","transcript_path":"/nonexistent.jsonl","cwd":"%s"}' "$sid" "$proj" \
    | HOME="$home" CLAUDE_SETTINGS_PATH=/nonexistent-thr-parity-settings.json "$BASH_BIN" "$GUARD" 2>/dev/null
}

if [ ! -f "$AUTOCKPT" ]; then
  fail "autocheckpoint.sh present next to the hooks" "expected at $AUTOCKPT"
else
  pass "autocheckpoint.sh present next to the hooks"

  # --- 1. crossing t2 writes the snapshot with no agent involvement ---------
  proj=$(mktempdir); home=$(mktempdir); mkdir -p "$proj/.agents"
  out=$(guard_at "$proj" "$home" 60 "t031a-$$-$RANDOM")
  snapfile=$(ls "$proj/.agents/runtime/handoff/"*.md 2>/dev/null | head -1)
  if [ -n "$snapfile" ] && printf '%s' "$out" | grep -q 'Авто-снимок состояния записан сам'; then
    pass "t2 crossing: snapshot written by the hook itself, path reported to the agent"
  else
    fail "t2 crossing: no snapshot" "file=${snapfile:-<none>} out=$out"
  fi

  # --- 2. CONTEXT_GUARD_THRESHOLDS still drives it --------------------------
  # 41% is below the default t2=60 but above a configured t2=40: a snapshot
  # here proves the auto-checkpoint follows the override, not a hardcoded 60.
  proj=$(mktempdir); home=$(mktempdir); mkdir -p "$proj/.agents"
  out=$(CONTEXT_GUARD_THRESHOLDS="30 40 50" guard_at "$proj" "$home" 41 "t031b-$$-$RANDOM")
  snapfile=$(ls "$proj/.agents/runtime/handoff/"*.md 2>/dev/null | head -1)
  if [ -n "$snapfile" ] && printf '%s' "$out" | grep -q 'Авто-снимок состояния записан сам'; then
    pass "CONTEXT_GUARD_THRESHOLDS=\"30 40 50\": snapshot fires at 41%, not at 60%"
  else
    fail "override did not drive the snapshot" "file=${snapfile:-<none>} out=$out"
  fi

  # --- 3. subagents are skipped, and a skip is NOT reported as a failure ----
  proj=$(mktempdir); home=$(mktempdir); mkdir -p "$proj/.agents"
  out=$(guard_at "$proj" "$home" 60 "agent-abc123")
  if [ ! -d "$proj/.agents/runtime/handoff" ] && ! printf '%s' "$out" | grep -q 'НЕ УДАЛОСЬ'; then
    pass "subagent session (agent-*): no snapshot file, and no false failure alarm"
  else
    fail "subagent handling wrong" "out=$out"
  fi

  # --- 4. PreCompact allows compaction once the snapshot exists ------------
  proj=$(mktempdir); home=$(mktempdir); mkdir -p "$proj/.agents"
  printf '{"session_id":"t031d-%s","trigger":"manual","cwd":"%s","transcript_path":"/nonexistent.jsonl"}' "$$" "$proj" \
    | HOME="$home" "$BASH_BIN" "$PRECOMPACT" >/dev/null 2>&1
  rc=$?
  snapfile=$(ls "$proj/.agents/runtime/handoff/"*.md 2>/dev/null | head -1)
  if [ "$rc" -eq 0 ] && [ -n "$snapfile" ]; then
    pass "PreCompact: snapshot written before compaction, rc=0 (compaction proceeds)"
  else
    fail "PreCompact happy path" "rc=$rc file=${snapfile:-<none>}"
  fi

  # --- 5/6. negative control: snapshot impossible -> loud + no compaction ---
  if [ "$IS_ROOT" = 1 ]; then
    fail "negative control skipped: running as root, chmod 555 cannot force a write failure"
  else
    proj=$(mktempdir); home=$(mktempdir)
    mkdir -p "$proj/.agents/runtime/handoff" "$home/.claude/context-state/handoff"
    chmod 555 "$proj/.agents/runtime/handoff" "$home/.claude/context-state/handoff"

    err=$(printf '{"session_id":"t031e-%s","trigger":"auto","cwd":"%s","transcript_path":"/nonexistent.jsonl"}' "$$" "$proj" \
      | HOME="$home" "$BASH_BIN" "$PRECOMPACT" 2>&1 >/dev/null)
    rc=$?
    if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -q 'COMPACTION STOPPED'; then
      pass "negative control: unwritable project AND home -> exit 2 (blocks compaction) + loud stderr"
    else
      fail "negative control: compaction was NOT blocked" "rc=$rc stderr=$err"
    fi

    out=$(guard_at "$proj" "$home" 60 "t031f-$$-$RANDOM")
    if printf '%s' "$out" | grep -q 'НЕ УДАЛОСЬ' && printf '%s' "$out" | grep -q '/compact'; then
      pass "negative control: guard at t2 says the snapshot failed and forbids compaction"
    else
      fail "guard stayed quiet about a failed snapshot" "out=$out"
    fi
    chmod 755 "$proj/.agents/runtime/handoff" "$home/.claude/context-state/handoff" 2>/dev/null
  fi
fi

finish
