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
group "Parity at pct=41: UTF-8 BOM in the config file (I-011, encoding robustness)"
# ===========================================================================
# A BOM (byte-order mark, EF BB BF) ahead of the JSON is common when a config
# is saved by a Windows editor. Both sides read it through the same shape of
# code (jq, which strips a BOM natively; or python3's `encoding="utf-8-sig"`,
# which strips it explicitly) — this case is a regression guard on that
# parity, not a claim that BOM is special-cased anywhere. Valid boundary
# config, so this belongs with the "1 default + 3 valid" group above in
# spirit; kept separate because it is testing encoding, not threshold values.
run_case "UTF-8 BOM ahead of valid config, 41 is yellow [40,60,80]" \
  $'\xEF\xBB\xBF{"thresholds":[40,60,80]}' yellow

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
  printf '{"pct": %s, "window": 1000000, "input_tokens": 800000, "updated": %s, "announced": 0}' \
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
  out=$(guard_at "$proj" "$home" 80 "t031a-$$-$RANDOM")
  snapfile=$(ls "$proj/.agents/runtime/handoff/"*.md 2>/dev/null | head -1)
  if [ -n "$snapfile" ] && printf '%s' "$out" | grep -q 'Авто-снимок состояния записан сам'; then
    pass "t2 crossing: snapshot written by the hook itself, path reported to the agent"
  else
    fail "t2 crossing: no snapshot" "file=${snapfile:-<none>} out=$out"
  fi

  # --- 2. the project's context-budget.json still drives it ----------------
  # 41% is below the default t2=80 but above a configured t2=40: a snapshot
  # here proves the auto-checkpoint follows the project override, not a
  # hardcoded 80.
  proj=$(mktempdir); home=$(mktempdir); mkdir -p "$proj/.agents"
  printf '%s' '{"thresholds":[30,40,50]}' > "$proj/.agents/context-budget.json"
  out=$(guard_at "$proj" "$home" 41 "t031b-$$-$RANDOM")
  snapfile=$(ls "$proj/.agents/runtime/handoff/"*.md 2>/dev/null | head -1)
  if [ -n "$snapfile" ] && printf '%s' "$out" | grep -q 'Авто-снимок состояния записан сам'; then
    pass "context-budget.json override [30,40,50]: snapshot fires at 41%, not at 80%"
  else
    fail "override did not drive the snapshot" "file=${snapfile:-<none>} out=$out"
  fi

  # --- 3. subagents are skipped, and a skip is NOT reported as a failure ----
  proj=$(mktempdir); home=$(mktempdir); mkdir -p "$proj/.agents"
  out=$(guard_at "$proj" "$home" 80 "agent-abc123")
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

    out=$(guard_at "$proj" "$home" 80 "t031f-$$-$RANDOM")
    if printf '%s' "$out" | grep -q 'НЕ УДАЛОСЬ' && printf '%s' "$out" | grep -q '/compact'; then
      pass "negative control: guard at t2 says the snapshot failed and forbids compaction"
    else
      fail "guard stayed quiet about a failed snapshot" "out=$out"
    fi
    chmod 755 "$proj/.agents/runtime/handoff" "$home/.claude/context-state/handoff" 2>/dev/null
  fi
fi

finish
