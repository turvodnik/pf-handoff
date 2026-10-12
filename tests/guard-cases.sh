#!/usr/bin/env bash
# guard-cases.sh — regression suite for the T-111 additions to the context
# hooks: window thresholds 40/60/75 % (T-164; no project budget), the 5h/7d
# rate-limit display, the advisor usage spike (a client project, 2026-09-16, 51 % ->
# "100 %" in one turn) and the PreCompact log field. One command: `bash tests/guard-cases.sh`.
#
# Every case runs the REAL hooks against a sandbox HOME and a temp project —
# the operator's ~/.claude/context-state is never touched. Bash 3.2 compatible
# (macOS system bash floor): no associative arrays, no mapfile. Self-contained
# on purpose, same harness style as threshold-parity.sh (copied, not sourced).
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$(cd "$TESTS_DIR/../hooks" && pwd)"
STATUSLINE="$HOOKS_DIR/statusline.sh"
GUARD="$HOOKS_DIR/context-guard.sh"
PRECOMPACT="$HOOKS_DIR/precompact.sh"
SESSIONSTART="$HOOKS_DIR/sessionstart.sh"
FIXTURE="$TESTS_DIR/fixtures/advisor-spike.jsonl"
BASH_BIN="$(command -v bash)"

for f in "$STATUSLINE" "$GUARD" "$PRECOMPACT" "$SESSIONSTART" "$FIXTURE"; do
  [ -f "$f" ] || { echo "cannot find $f"; exit 90; }
done

PASS=0; FAIL=0; FAIL_LABELS=(); CURRENT_GROUP=""; GROUP_PASS=0; GROUP_FAIL=0
GROUP_SUMMARY=(); CLEANUP_DIRS=()
group() {
  if [ -n "$CURRENT_GROUP" ]; then GROUP_SUMMARY+=("$CURRENT_GROUP: $GROUP_PASS/$((GROUP_PASS + GROUP_FAIL))"); fi
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
  if [ -n "$CURRENT_GROUP" ]; then GROUP_SUMMARY+=("$CURRENT_GROUP: $GROUP_PASS/$((GROUP_PASS + GROUP_FAIL))"); fi
  echo; echo "=== SUMMARY ==="
  local line; for line in "${GROUP_SUMMARY[@]+"${GROUP_SUMMARY[@]}"}"; do echo "$line"; done
  echo "TOTAL: $PASS/$((PASS + FAIL))"
  if [ "$FAIL" -gt 0 ]; then echo; echo "Failed:"; local l; for l in "${FAIL_LABELS[@]+"${FAIL_LABELS[@]}"}"; do echo "  - $l"; done; fi
  local d; for d in "${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}"; do [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"; done
  if [ "$FAIL" -eq 0 ]; then echo "RESULT: GREEN"; return 0; else echo "RESULT: RED"; return 1; fi
}
mktempdir() { local d; d=$(mktemp -d "${TMPDIR:-/tmp}/guard-cases.XXXXXXXX"); CLEANUP_DIRS+=("$d"); printf '%s' "$d"; }

echo "guard-cases.sh — context-hooks regression suite (T-111)"
echo "guard:      $GUARD"
echo "statusline: $STATUSLINE"
echo "bash:       $BASH_BIN ($("$BASH_BIN" --version | head -1))"

# --- helpers ----------------------------------------------------------------
# seed_state HOME SID JSON-BODY — writes a fresh (updated=now) state file.
seed_state() {
  local home="$1" sid="$2" body="$3" now
  mkdir -p "$home/.claude/context-state"
  now=$(date +%s)
  printf '%s' "$body" | sed "s/@NOW@/$now/" > "$home/.claude/context-state/$sid.json"
  # A seeded state must be valid JSON: jq reads the first value of a broken
  # file and the python3 branch reads {} — a typo would pass unnoticed.
  if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$home/.claude/context-state/$sid.json" 2>/dev/null; then
    fail "seed_state: invalid JSON in the seeded state $sid" "$(cat "$home/.claude/context-state/$sid.json")"
  fi
}
# run_guard HOME PROJ SID [TRANSCRIPT] — prints the guard's stdout; the exit
# code lands in $home/.guard-rc (a $(...) capture runs in a subshell, so a
# plain variable would not reach the caller).
run_guard() {
  local home="$1" proj="$2" sid="$3" tp="${4:-/nonexistent.jsonl}" out
  out=$(printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","transcript_path":"%s","cwd":"%s"}' "$sid" "$tp" "$proj" \
    | HOME="$home" CLAUDE_SETTINGS_PATH=/nonexistent-guard-cases-settings.json "$BASH_BIN" "$GUARD" 2>/dev/null)
  echo $? > "$home/.guard-rc"
  printf '%s' "$out"
}
guard_rc() { cat "$1/.guard-rc" 2>/dev/null || echo 99; }
# run_statusline HOME PROJ SID SESSION_PCT [RESET_EPOCH] — feeds a status-line
# payload with rate_limits and returns rc; state lands in HOME.
run_statusline() {
  local home="$1" proj="$2" sid="$3" five="$4" reset="${5:-$(( $(date +%s) + 8000 ))}"
  printf '{"session_id":"%s","context_window":{"used_percentage":30,"context_window_size":1000000,"total_input_tokens":300000},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":12,"resets_at":%s}},"workspace":{"current_dir":"%s"},"cwd":"%s"}' \
    "$sid" "$five" "$reset" "$(( reset + 500000 ))" "$proj" "$proj" \
    | HOME="$home" PF_STATUSLINE_CONFIG=/nonexistent-guard-cases-cfg.json CONTEXT_HOOKS_ORCA_STATUSLINE=/nonexistent-orca.sh "$BASH_BIN" "$STATUSLINE" >/dev/null 2>&1
}
state_field() { # state_field FILE KEY -> raw value (number or "string")
  grep -oE "\"$2\":[[:space:]]*(\"[^\"]*\"|[-0-9.]+|null)" "$1" 2>/dev/null | head -1 | sed -E "s/^\"$2\":[[:space:]]*//"
}

# ===========================================================================
group "T-164 window thresholds 40/60/75 %, env override, no project budget"
# ===========================================================================
# mk_t1m PATH TOKENS — a 1M-window transcript (claude-opus-5-5, TOKENS in context).
mk_t1m() {
  printf '{"type":"user","message":{"role":"user","content":"go"}}\n{"type":"assistant","message":{"model":"claude-opus-5-5","id":"m1","role":"assistant","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}\n' "$2" > "$1"
}
# zone_of OUT -> 0|1|2|3 by the mandatory phrases of the zone texts.
zone_of() {
  case "$1" in
    *"финальный pf-handoff; доведи шаг до проверяемой точки"*) echo 3 ;;
    *"полный pf-handoff; новых M/L не начинать"*) echo 2 ;;
    *"короткий чекпоинт HANDOFF"*) echo 1 ;;
    *) echo 0 ;;
  esac
}
proj=$(mktempdir); home=$(mktempdir)
for pair in 39:0 41:1 59:1 61:2 74:2 76:3; do
  p=${pair%%:*}; want=${pair##*:}
  mk_t1m "$home/t$p.jsonl" $(( p * 10000 ))
  out=$(run_guard "$home" "$proj" "w1m$p" "$home/t$p.jsonl")
  got=$(zone_of "$out")
  if [ "$got" = "$want" ]; then pass "1M window (transcript), $p % -> zone $want"; else fail "1M $p % expected zone $want, got $got" "out=$out"; fi
done
for pair in 39:0 41:1 61:2 76:3; do
  p=${pair%%:*}; want=${pair##*:}
  seed_state "$home" "w2k$p" "{\"pct\": $p, \"window\": 200000, \"input_tokens\": $(( p * 2000 )), \"updated\": @NOW@, \"announced\": 0, \"state_version\": 2}"
  out=$(run_guard "$home" "$proj" "w2k$p")
  got=$(zone_of "$out")
  if [ "$got" = "$want" ]; then pass "200k window (state), $p % -> zone $want"; else fail "200k $p % expected zone $want, got $got" "out=$out"; fi
done
# Env override: "30 50 70" moves the boundaries; garbage values fall back to 40/60/75.
env_zone() { # env_zone VALUE PCT -> zone
  local v="$2" sid; sid="env_$$_$(printf '%s_%s' "$1" "$2" | tr -c 'a-zA-Z0-9\n' _)"
  mk_t1m "$home/e.jsonl" $(( v * 10000 ))
  zone_of "$(printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","transcript_path":"%s","cwd":"%s"}' "$sid" "$home/e.jsonl" "$proj" \
    | HOME="$home" CLAUDE_SETTINGS_PATH=/nonexistent-guard-cases-settings.json CONTEXT_GUARD_THRESHOLDS="$1" "$BASH_BIN" "$GUARD" 2>/dev/null)"
}
for c in "30 50 70|31|1" "30 50 70|51|2" "30 50 70|71|3" "30 50 70|29|0" "050 060 070|51|1"; do
  v=${c%%|*}; rest=${c#*|}; p=${rest%%|*}; want=${rest##*|}
  got=$(env_zone "$v" "$p")
  if [ "$got" = "$want" ]; then pass "CONTEXT_GUARD_THRESHOLDS='$v', $p % -> zone $want"; else fail "env '$v' at $p % expected zone $want, got $got"; fi
done
# Malformed values are ignored (41 % stays zone 1, as with the defaults; accepted
# they would give zone 3 or 0).
for v in "20 25" "20 25 30 35" "30 25 20" "20.5 25 30" "+20 25 30" "a b c" "0 5 10" "20 25 100" "20,25,30"; do
  got=$(env_zone "$v" 41)
  if [ "$got" = "1" ]; then pass "malformed CONTEXT_GUARD_THRESHOLDS='$v' -> defaults (41 % = zone 1)"; else fail "malformed '$v' was accepted: zone $got"; fi
done
# A leftover project budget file is not read: no «бюджет» wording, defaults apply
# (410k of 1M with budget 600000 would be 68 % of the budget = zone 2).
mkdir -p "$proj/.agents"; printf '%s' '{"thresholds":[10,20,30],"budget_tokens":600000}' > "$proj/.agents/context-budget.json"
mk_t1m "$home/b.jsonl" 410000
out=$(run_guard "$home" "$proj" "bfile" "$home/b.jsonl")
if [ "$(zone_of "$out")" = "1" ] && ! printf '%s' "$out" | grep -q 'бюджет' && printf '%s' "$out" | grep -q 'занято 41%'; then
  pass "context-budget.json (thresholds + budget_tokens) is ignored: 41 % of the window, zone 1, no 'бюджет'"
else
  fail "project budget file still read" "out=$out"
fi
rm -f "$proj/.agents/context-budget.json"
# Without jq (python3 fallback of the hook): same zones. A PATH of symlinks to
# everything except jq; the probe proves jq is really absent from it.
nojq=$(mktempdir)
for tool in bash sh cat sed awk tr cut head tail grep date mkdir mktemp rm ls python3 python dirname basename printf stat wc sort uniq tee readlink git env id touch mv cp ln; do
  tp=$(command -v "$tool" 2>/dev/null) && [ -x "$tp" ] && ln -s "$tp" "$nojq/$tool"
done
if PATH="$nojq" command -v jq >/dev/null 2>&1; then
  fail "no-jq PATH still contains jq (probe broken)"
else
  mk_t1m "$home/nj.jsonl" 410000
  out=$(printf '{"session_id":"nojq1","hook_event_name":"UserPromptSubmit","transcript_path":"%s","cwd":"%s"}' "$home/nj.jsonl" "$proj" \
    | env -i HOME="$home" PATH="$nojq" CLAUDE_SETTINGS_PATH=/nonexistent-guard-cases-settings.json "$BASH_BIN" "$GUARD" 2>/dev/null)
  if [ "$(zone_of "$out")" = "1" ]; then pass "no jq on PATH: 41 % of 1M -> zone 1 (python3 fallback)"; else fail "guard without jq" "out=$out"; fi
fi

# ===========================================================================
group "statusline.sh: 5h/7d percents are shown to the human, never written to state (T-163)"
# ===========================================================================
proj=$(mktempdir); home=$(mktempdir)
run_statusline "$home" "$proj" "s1" 87 "$(( $(date +%s) + 3600 ))"; rc=$?
sf="$home/.claude/context-state/s1.json"
if [ "$rc" -eq 0 ] && [ -s "$sf" ] && [ "$(state_field "$sf" pct)" = "30" ] && ! grep -qE 'five_|seven_|announced_limits' "$sf"; then
  pass "payload with rate_limits -> state keeps pct/window/input_tokens/updated/announced only (no limit fields)"
else
  fail "statusline state fields" "rc=$rc state=$(cat "$sf" 2>/dev/null)"
fi
sl_plain=$(printf '{"session_id":"s1b","context_window":{"used_percentage":30,"context_window_size":1000000,"total_input_tokens":300000},"rate_limits":{"five_hour":{"used_percentage":12.5,"resets_at":%s},"seven_day":{"used_percentage":42.0,"resets_at":%s}},"workspace":{"current_dir":"%s"},"cwd":"%s"}' \
    "$(( $(date +%s) + 8000 ))" "$(( $(date +%s) + 500000 ))" "$proj" "$proj" \
  | HOME="$home" PF_STATUSLINE_CONFIG=/nonexistent-guard-cases-cfg.json CONTEXT_HOOKS_ORCA_STATUSLINE=/nonexistent-orca.sh "$BASH_BIN" "$STATUSLINE" 2>/dev/null | sed $'s/\033\[[0-9;]*m//g')
if printf '%s' "$sl_plain" | grep -q 'Session: 12.5%.*Weekly: 42.0%' && ! printf '%s' "$sl_plain" | grep -q 'L:'; then
  pass "the line still shows 'Session: 12.5%' and 'Weekly: 42.0%' (human display), no 'L:' helpers segment"
else
  fail "statusline human display of 5h/7d" "out=$sl_plain"
fi
# T-164: a leftover budget file is not read — the line is the plain window form,
# the bar colour follows 40/60 % of the window (30 % green, 45 % yellow, 65 % red).
mkdir -p "$proj/.agents"; printf '%s' '{"budget_tokens":400000,"thresholds":[10,20,30]}' > "$proj/.agents/context-budget.json"
sl_for() { # sl_for SID PCT -> raw line
  printf '{"session_id":"%s","context_window":{"used_percentage":%s,"context_window_size":1000000,"total_input_tokens":%s},"cwd":"%s","workspace":{"current_dir":"%s"}}' "$1" "$2" "$(( $2 * 10000 ))" "$proj" "$proj" \
    | HOME="$home" PF_STATUSLINE_CONFIG=/nonexistent-guard-cases-cfg.json CONTEXT_HOOKS_ORCA_STATUSLINE=/nonexistent-orca.sh "$BASH_BIN" "$STATUSLINE" 2>/dev/null
}
sl_out=$(sl_for s3 30); sl_plain=$(printf '%s' "$sl_out" | sed $'s/\033\[[0-9;]*m//g')
if printf '%s' "$sl_plain" | grep -q '300k/1.0M (30%)' && ! printf '%s' "$sl_plain" | grep -q 'бюджет' && printf '%s' "$sl_out" | grep -q $'\033\[32m30%' && [ "$(state_field "$home/.claude/context-state/s3.json" pct)" = "30" ]; then
  pass "budget file ignored by the status line: '300k/1.0M (30%)', no 'бюджет', green, state pct=30"
else
  fail "statusline still reads the budget file" "out=$sl_out"
fi
if sl_for s3y 45 | grep -q $'\033\[33m45%' && sl_for s3r 65 | grep -q $'\033\[31m65%'; then
  pass "status line colours at 40/60 % of the window: 45 % yellow, 65 % red"
else
  fail "status line zone colours not 40/60"
fi

# ===========================================================================
group "advisor usage spike (a client project, 2026-09-16 12:45): 51% must not read as 100%"
# ===========================================================================
# The fixture is transcript lines 2994–3003 stripped to service fields: the
# honest turn (515 357 tokens) followed by an advisor turn whose top-level
# usage sums two main-model iterations (1 033 942). statusline had already
# written pct=100 / input_tokens=1033942 into state (the harness reports the
# same top-level sum), so the guard must recognise the spike from the
# transcript and read the last `type: message` iteration instead.
proj=$(mktempdir); home=$(mktempdir)
seed_state "$home" "spike" '{"pct": 100, "window": 1000000, "input_tokens": 1033942, "updated": @NOW@, "announced": 0, "state_version": 2}'
out=$(run_guard "$home" "$proj" "spike" "$FIXTURE")
if [ "$(guard_rc "$home")" -eq 0 ] && printf '%s' "$out" | grep -q 'занято 51%' && [ "$(zone_of "$out")" = "1" ]; then
  pass "state 100%/1033942 + advisor fixture -> real context 51%, zone 1 (not the doubled 100%)"
else
  fail "advisor spike announced as a real threshold" "rc=$(guard_rc "$home") out=$out"
fi
# Fallback path (stale state): same fixture, guard estimates from the transcript.
seed_state "$home" "spike2" '{"pct": 100, "window": 1000000, "input_tokens": 1033942, "updated": 1000, "announced": 0}'
out=$(run_guard "$home" "$proj" "spike2" "$FIXTURE")
if [ "$(guard_rc "$home")" -eq 0 ] && printf '%s' "$out" | grep -q 'занято 51%' && [ "$(zone_of "$out")" = "1" ]; then
  pass "stale state (fallback by transcript) + advisor fixture -> 51 %, zone 1"
else
  fail "fallback path still trusts the doubled usage" "rc=$(guard_rc "$home") out=$out state=$(cat "$home/.claude/context-state/spike2.json")"
fi
# Negative control: the same numbers WITHOUT iterations (an honest 1.03M turn)
# must still be announced — the filter is specific to multi-iteration usage.
ctrl=$(mktempdir)/honest.jsonl
python3 - "$FIXTURE" "$ctrl" <<'EOF'
import json, sys
with open(sys.argv[1]) as f, open(sys.argv[2], "w") as g:
    for line in f:
        d = json.loads(line)
        u = (d.get("message") or {}).get("usage")
        if u: u.pop("iterations", None)
        g.write(json.dumps(d, separators=(",", ":")) + "\n")
EOF
seed_state "$home" "ctrl" '{"pct": 100, "window": 1000000, "input_tokens": 1033942, "updated": @NOW@, "announced": 0, "state_version": 2}'
out=$(run_guard "$home" "$proj" "ctrl" "$ctrl")
if printf '%s' "$out" | grep -q 'занято 100%'; then
  pass "negative control: same usage without iterations -> 100% announced (filter is specific)"
else
  fail "negative control: honest 100% was suppressed" "out=$out"
fi
# A usage line cut by `tail -c 200000`: the last turn wrote a >200 KB tool
# result, the state is stale (>300 s), so the fallback must still read the
# honest numbers that survive at the END of the cut line — not 0 (which would
# silently reset `announced`).
proj=$(mktempdir); home=$(mktempdir)   # fresh project
big=$(mktempdir)/big.jsonl
python3 - "$big" <<'EOF'
import json, sys
row = {"type": "assistant", "message": {"id": "msg_big", "role": "assistant",
       "content": [{"type": "text", "text": "x" * 250000}],
       "usage": {"input_tokens": 2, "cache_creation_input_tokens": 998, "cache_read_input_tokens": 849000}}}
with open(sys.argv[1], "w") as g:
    g.write(json.dumps(row, separators=(",", ":")) + "\n")
EOF
seed_state "$home" "big" '{"pct": 10, "window": 1000000, "input_tokens": 100000, "updated": 1000, "announced": 0}'
out=$(run_guard "$home" "$proj" "big" "$big")
if printf '%s' "$out" | grep -q 'занято 85%' && [ "$(state_field "$home/.claude/context-state/big.json" input_tokens)" = "850000" ] && [ "$(state_field "$home/.claude/context-state/big.json" pct)" = "85" ]; then
  pass "usage line cut by tail -c (250 KB content): fallback still reads 850000 tokens -> 85%"
else
  fail "cut usage line read as 0" "out=$out state=$(cat "$home/.claude/context-state/big.json" 2>/dev/null)"
fi

# ===========================================================================
group "compatibility: old state (5 fields) and broken state never block the session"
# ===========================================================================
proj=$(mktempdir); home=$(mktempdir)
seed_state "$home" "old" '{"pct": 85, "window": 200000, "input_tokens": 170000, "updated": @NOW@, "announced": 0}'
out=$(run_guard "$home" "$proj" "old")
sf="$home/.claude/context-state/old.json"
# An old 5-field state (v1.10.0, no state_version) is read without error, but
# even fresh its numbers are not trusted (QA 2.0.0, N2): no transcript here ->
# nothing to announce, rc 0.
if [ "$(guard_rc "$home")" -eq 0 ] && [ -z "$out" ]; then
  pass "old 5-field state (fresh, no state_version): rc 0, its 85 % is not taken as is (N2)"
else
  fail "old state compatibility" "rc=$(guard_rc "$home") out=$out state=$(cat "$sf" 2>/dev/null)"
fi
mkdir -p "$home/.claude/context-state"; printf 'not json at all {{{' > "$home/.claude/context-state/broken.json"
out=$(run_guard "$home" "$proj" "broken")
if [ "$(guard_rc "$home")" -eq 0 ]; then
  pass "garbage state file -> rc=0 (session not blocked)"
else
  fail "garbage state crashed the hook" "rc=$(guard_rc "$home") out=$out"
fi

# ===========================================================================
group "precompact.sh logs whether the guard had announced t2"
# ===========================================================================
proj=$(mktempdir); home=$(mktempdir); mkdir -p "$proj/.agents"
seed_state "$home" "pc1" '{"pct": 85, "window": 1000000, "input_tokens": 850000, "updated": @NOW@, "announced": 80, "state_version": 2}'
printf '{"session_id":"pc1","trigger":"auto","cwd":"%s","transcript_path":"/nonexistent.jsonl"}' "$proj" \
  | HOME="$home" "$BASH_BIN" "$PRECOMPACT" >/dev/null 2>&1
if grep -q 'pc1 auto .* OK .* guard announced t2: yes (announced=80)' "$home/.claude/context-state/compacts.log" 2>/dev/null; then
  pass "announced=80 (above the default t2=60) -> 'guard announced t2: yes (announced=80)'"
else
  fail "precompact t2 field (yes)" "log=$(cat "$home/.claude/context-state/compacts.log" 2>/dev/null)"
fi
seed_state "$home" "pc2" '{"pct": 65, "window": 1000000, "input_tokens": 650000, "updated": @NOW@, "announced": 60, "state_version": 2}'
printf '{"session_id":"pc2","trigger":"auto","cwd":"%s","transcript_path":"/nonexistent.jsonl"}' "$proj" \
  | HOME="$home" "$BASH_BIN" "$PRECOMPACT" >/dev/null 2>&1
# T-166: t2 is the guard's (default 60, T-164) — announced=60 IS t2. Before
# T-166 precompact still took t2=80 and logged a false "no" here.
if grep -q 'pc2 auto .* OK .* guard announced t2: yes (announced=60)' "$home/.claude/context-state/compacts.log" 2>/dev/null; then
  pass "announced=60 (default t2=60, same as the guard) -> 'guard announced t2: yes (announced=60)'"
else
  fail "precompact t2 field (default 60)" "log=$(cat "$home/.claude/context-state/compacts.log" 2>/dev/null)"
fi
# Env override "30 40 50": announced=40 IS t2 there.
seed_state "$home" "pc3" '{"pct": 45, "window": 1000000, "input_tokens": 450000, "updated": @NOW@, "announced": 40, "state_version": 2}'
printf '{"session_id":"pc3","trigger":"auto","cwd":"%s","transcript_path":"/nonexistent.jsonl"}' "$proj" \
  | HOME="$home" CONTEXT_GUARD_THRESHOLDS="30 40 50" "$BASH_BIN" "$PRECOMPACT" >/dev/null 2>&1
if grep -q 'pc3 auto .* OK .* guard announced t2: yes (announced=40)' "$home/.claude/context-state/compacts.log" 2>/dev/null; then
  pass "CONTEXT_GUARD_THRESHOLDS='30 40 50', announced=40 -> yes (follows the env t2)"
else
  fail "precompact t2 field (env override)" "log=$(cat "$home/.claude/context-state/compacts.log" 2>/dev/null)"
fi
# Env override "30 70 80": announced=60 is below that t2 -> "no" (the negative
# half: t2 really moves with the env, it is not a constant yes).
seed_state "$home" "pc4" '{"pct": 65, "window": 1000000, "input_tokens": 650000, "updated": @NOW@, "announced": 60, "state_version": 2}'
printf '{"session_id":"pc4","trigger":"auto","cwd":"%s","transcript_path":"/nonexistent.jsonl"}' "$proj" \
  | HOME="$home" CONTEXT_GUARD_THRESHOLDS="30 70 80" "$BASH_BIN" "$PRECOMPACT" >/dev/null 2>&1
if grep -q 'pc4 auto .* OK .* guard announced t2: no (announced=60)' "$home/.claude/context-state/compacts.log" 2>/dev/null; then
  pass "CONTEXT_GUARD_THRESHOLDS='30 70 80', announced=60 -> no (below the env t2)"
else
  fail "precompact t2 field (env override, no)" "log=$(cat "$home/.claude/context-state/compacts.log" 2>/dev/null)"
fi
# A leftover project budget file is ignored (T-164 removed it): [30,40,50] in
# the file, announced=40, no env -> default t2=60 -> "no".
printf '%s' '{"thresholds":[30,40,50]}' > "$proj/.agents/context-budget.json"
seed_state "$home" "pc5" '{"pct": 45, "window": 1000000, "input_tokens": 450000, "updated": @NOW@, "announced": 40, "state_version": 2}'
printf '{"session_id":"pc5","trigger":"auto","cwd":"%s","transcript_path":"/nonexistent.jsonl"}' "$proj" \
  | HOME="$home" "$BASH_BIN" "$PRECOMPACT" >/dev/null 2>&1
if grep -q 'pc5 auto .* OK .* guard announced t2: no (announced=40)' "$home/.claude/context-state/compacts.log" 2>/dev/null; then
  pass "leftover context-budget.json [30,40,50] ignored, announced=40 -> no (default t2=60)"
else
  fail "precompact t2 field (budget file ignored)" "log=$(cat "$home/.claude/context-state/compacts.log" 2>/dev/null)"
fi

# ===========================================================================
group "T-154 window from the transcript model, not the settings alias (audit 02.10 Н1)"
# ===========================================================================
# Without a fresh status-line state (Claude desktop, idle >300 s) the old guard
# guessed the window from the `.model` alias in settings.json — and `/model`
# rewrites that alias (`opus[1m]` -> `opus` -> `fable`). With `opus` it took
# 200k for a 1M model: 160k tokens read as "80 %", 181k as "90 % — немедленно
# pf-handoff" (live desktop session 51fd4d20, 02.10). The window now follows the
# model of the last assistant reply in the transcript; family 5 -> 1M.
# mk_transcript PATH MODEL TOKENS [EXTRA_LINE] — a human prompt and one
# assistant reply of MODEL with TOKENS of context (input only; the cache fields
# are present because the guard finds the usage line by them).
mk_transcript() {
  mkdir -p "$(dirname "$1")"
  printf '{"type":"user","message":{"role":"user","content":"go"}}\n' > "$1"
  printf '{"type":"assistant","message":{"model":"%s","id":"msg_t154","role":"assistant","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}\n' "$2" "$3" >> "$1"
  [ -n "${4:-}" ] && printf '%s\n' "$4" >> "$1"
  return 0
}
# run_guard_dbg HOME PROJ SID TRANSCRIPT [EXTRA_INPUT_FIELDS] — run_guard with
# the settings alias the old guard read (HOME/.claude/settings.json, `opus`)
# and CONTEXT_GUARD_DEBUG=1; the debug stderr lands in HOME/.guard-err.
run_guard_dbg() {
  local home="$1" proj="$2" sid="$3" tp="$4" extra="${5:-}" out
  mkdir -p "$home/.claude"; printf '%s' '{"model":"opus"}' > "$home/.claude/settings.json"
  out=$(printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","transcript_path":"%s","cwd":"%s"%s}' "$sid" "$tp" "$proj" "$extra" \
    | HOME="$home" CLAUDE_SETTINGS_PATH="$home/.claude/settings.json" CONTEXT_GUARD_DEBUG=1 "$BASH_BIN" "$GUARD" 2>"$home/.guard-err")
  echo $? > "$home/.guard-rc"
  printf '%s' "$out"
}
# 1. The audit repro: alias `opus`, no state, claude-opus-5-5 at 160k -> 16 % of 1M.
proj=$(mktempdir); home=$(mktempdir); tp="$home/w1.jsonl"
mk_transcript "$tp" "claude-opus-5-5" 160000
out=$(run_guard_dbg "$home" "$proj" "w1" "$tp")
if [ "$(guard_rc "$home")" -eq 0 ] && [ -z "$out" ] && grep -q 'окно 1000000' "$home/.guard-err"; then
  pass "alias 'opus' + claude-opus-5-5 at 160k, no state -> silent (window 1M from the model, not 200k)"
else
  fail "160k of a family-5 model announced against a 200k window" "rc=$(guard_rc "$home") out=$out dbg=$(cat "$home/.guard-err" 2>/dev/null)"
fi
# 2. A window the guard guessed and wrote itself (window_guess: 1, 200000,
#    stale) must not keep the session on 200k: a family-5 model overrides it,
#    and the state heals (still marked as a guess).
proj=$(mktempdir); home=$(mktempdir); tp="$home/w2.jsonl"
mk_transcript "$tp" "claude-opus-5-5" 160000
seed_state "$home" "w2" '{"pct": 50, "window": 200000, "input_tokens": 100000, "updated": 1000, "announced": 60, "window_guess": 1}'
out=$(run_guard_dbg "$home" "$proj" "w2" "$tp")
if [ -z "$out" ] && [ "$(state_field "$home/.claude/context-state/w2.json" window)" = "1000000" ] && [ "$(state_field "$home/.claude/context-state/w2.json" announced)" = "0" ] \
   && [ "$(state_field "$home/.claude/context-state/w2.json" window_guess)" = "1" ]; then
  pass "stale guard-guessed state window 200000 + claude-opus-5-5 -> silent, state healed to window 1000000 (window_guess 1)"
else
  fail "stale 200k window still trusted for a family-5 model" "out=$out state=$(cat "$home/.claude/context-state/w2.json" 2>/dev/null)"
fi
# 3. Discriminating control (green before and after the fix — it guards against
#    a "constant 1M" shortcut): the SAME stale 200k state and the same 160k, but
#    a model the guard does not know -> the last known window (200k) is kept.
proj=$(mktempdir); home=$(mktempdir); tp="$home/w3.jsonl"
mk_transcript "$tp" "claude-nova-1" 160000
seed_state "$home" "w3" '{"pct": 50, "window": 200000, "input_tokens": 100000, "updated": 1000, "announced": 0}'
out=$(run_guard_dbg "$home" "$proj" "w3" "$tp")
if printf '%s' "$out" | grep -q 'занято 80%'; then
  pass "control: unknown model + stale state window 200000 -> that window is used (80% announced): the model is really read"
else
  fail "control: unknown model did not fall back to the state window" "out=$out"
fi
# 4. Unknown model, nothing else known -> 1M, marked «предположено» in the debug line.
proj=$(mktempdir); home=$(mktempdir); tp="$home/w4.jsonl"
mk_transcript "$tp" "claude-nova-1" 160000
out=$(run_guard_dbg "$home" "$proj" "w4" "$tp")
if [ -z "$out" ] && grep -q 'окно 1000000' "$home/.guard-err" && grep -q 'предположено' "$home/.guard-err" && grep -q 'claude-nova-1' "$home/.guard-err"; then
  pass "unknown model, no state -> window 1M, debug line says 'предположено' and names the model"
else
  fail "unknown model not assumed 1M / not marked" "out=$out dbg=$(cat "$home/.guard-err" 2>/dev/null)"
fi
# 5. Negative control: the guard is not simply muted — a family-5 model at 850k
#    is announced as 85 % of 1M and the state records window 1000000.
proj=$(mktempdir); home=$(mktempdir); tp="$home/w5.jsonl"
mk_transcript "$tp" "claude-fable-5-1" 850000
out=$(run_guard_dbg "$home" "$proj" "w5" "$tp")
if printf '%s' "$out" | grep -q 'занято 85%' && [ "$(state_field "$home/.claude/context-state/w5.json" window)" = "1000000" ]; then
  pass "negative control: claude-fable-5-1 at 850k -> 'занято 85%' of a 1M window"
else
  fail "negative control: family-5 at 850k not announced as 85%" "out=$out state=$(cat "$home/.claude/context-state/w5.json" 2>/dev/null)"
fi
# 6. A `<synthetic>` reply (Claude Code writes one after an interrupt) is not a
#    model: the window follows the last REAL reply. Picking `<synthetic>` would
#    make it "unknown" and fall back to the stale 200k state -> a false 80 %.
proj=$(mktempdir); home=$(mktempdir); tp="$home/w6.jsonl"
mk_transcript "$tp" "claude-opus-5-5" 160000 '{"type":"assistant","message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"No response requested."}]}}'
seed_state "$home" "w6" '{"pct": 50, "window": 200000, "input_tokens": 100000, "updated": 1000, "announced": 0, "window_guess": 1}'
out=$(run_guard_dbg "$home" "$proj" "w6" "$tp")
if [ -z "$out" ] && grep -q 'claude-opus-5-5' "$home/.guard-err"; then
  pass "a trailing <synthetic> reply is skipped: model claude-opus-5-5, window 1M, silent"
else
  fail "<synthetic> taken as the model" "out=$out dbg=$(cat "$home/.guard-err" 2>/dev/null)"
fi
# 7. A family name must be read exactly: claude-haiku-4-5-… contains "-5" but
#    is NOT family 5 — with a stale 200k state it keeps that window (80 %).
proj=$(mktempdir); home=$(mktempdir); tp="$home/w7.jsonl"
mk_transcript "$tp" "claude-haiku-4-5-20251001" 160000
seed_state "$home" "w7" '{"pct": 50, "window": 200000, "input_tokens": 100000, "updated": 1000, "announced": 0}'
out=$(run_guard_dbg "$home" "$proj" "w7" "$tp")
if printf '%s' "$out" | grep -q 'занято 80%'; then
  pass "claude-haiku-4-5-20251001 is not family 5 (the '-5' after '-4' does not count) -> stale 200k kept, 80%"
else
  fail "claude-haiku-4-5 misread as family 5" "out=$out dbg=$(cat "$home/.guard-err" 2>/dev/null)"
fi
# 8. Precedence (green before and after): a FRESH status-line state is the
#    harness's own number and wins over the model — window 200000 there stays.
proj=$(mktempdir); home=$(mktempdir); tp="$home/w8.jsonl"
mk_transcript "$tp" "claude-opus-5-5" 160000
seed_state "$home" "w8" '{"pct": 80, "window": 200000, "input_tokens": 160000, "updated": @NOW@, "announced": 0, "state_version": 2}'
out=$(run_guard_dbg "$home" "$proj" "w8" "$tp")
if printf '%s' "$out" | grep -q 'занято 80%'; then
  pass "precedence: a fresh status-line state (window 200000) is trusted over the transcript model"
else
  fail "fresh status-line window overridden" "out=$out"
fi
# 8b. QA 2.0.0 Y9: a STALE state the status line wrote (window 200000, no
#     window_guess) is still the harness's number — it wins over the
#     "family 5 => 1M" rule: 150010 tokens of claude-opus-5-5 = 75 % of 200k.
proj=$(mktempdir); home=$(mktempdir); tp="$home/w8b.jsonl"
mk_transcript "$tp" "claude-opus-5-5" 150010
seed_state "$home" "w8b" '{"pct": 70, "window": 200000, "input_tokens": 140000, "updated": 1000, "announced": 60, "state_version": 2}'
out=$(run_guard_dbg "$home" "$proj" "w8b" "$tp")
if printf '%s' "$out" | grep -q 'занято 75%' && grep -q 'окно 200000 (из состояния статус-строки)' "$home/.guard-err" \
   && [ "$(state_field "$home/.claude/context-state/w8b.json" window)" = "200000" ] \
   && [ "$(state_field "$home/.claude/context-state/w8b.json" window_guess)" != "1" ]; then
  pass "Y9: stale status-line state window 200000 + claude-opus-5-5 at 150010 -> 75 % of 200k (state window beats the family rule)"
else
  fail "Y9: family-5 rule overrode the status line's 200k window" "out=$out dbg=$(cat "$home/.guard-err" 2>/dev/null)"
fi
# 8b2. QA 2.0.0 N2: the SAME stale state in the v1.10.0 format (no
#      state_version) — the old guard wrote its alias guess (200000 for
#      `opus`) there unmarked, so it is a guess: claude-opus-5-5 at 150010 is
#      15 % of 1M, no directive; whenever the guard rewrites that state it is
#      version 2 WITH window_guess 1, never a promoted status-line window.
proj=$(mktempdir); home=$(mktempdir); tp="$home/w8l.jsonl"
mk_transcript "$tp" "claude-opus-5-5" 150010
seed_state "$home" "w8l" '{"pct": 75, "window": 200000, "input_tokens": 150010, "updated": 1000, "announced": 0}'
out=$(run_guard_dbg "$home" "$proj" "w8l" "$tp")
sf="$home/.claude/context-state/w8l.json"
if [ -z "$out" ] && grep -q 'окно 1000000 (по модели транскрипта)' "$home/.guard-err" && grep -q 'занято 15%' "$home/.guard-err" \
   && ! { [ "$(state_field "$sf" state_version)" = "2" ] && [ "$(state_field "$sf" window_guess)" != "1" ]; }; then
  pass "N2: v1.10.0 state (window 200000, no state_version) + claude-opus-5-5 at 150010 -> 15 % of 1M, silent; the state is never promoted to a status-line window"
else
  fail "N2: a v1.10.0 state window taken for the status line's number" "out=$out dbg=$(cat "$home/.guard-err" 2>/dev/null) state=$(cat "$sf" 2>/dev/null)"
fi
# 8b2f. Fix round 1: the SAME v1.10.0 state, but FRESH (30 s old, inside the
#       300 s freshness window) — still a guess, not taken as is: 15 % of 1M.
proj=$(mktempdir); home=$(mktempdir); tp="$home/w8f.jsonl"
mk_transcript "$tp" "claude-opus-5-5" 150010
seed_state "$home" "w8f" "{\"pct\": 75, \"window\": 200000, \"input_tokens\": 150010, \"updated\": $(( $(date +%s) - 30 )), \"announced\": 0}"
out=$(run_guard_dbg "$home" "$proj" "w8f" "$tp")
if [ -z "$out" ] && grep -q 'окно 1000000 (по модели транскрипта)' "$home/.guard-err" && grep -q 'занято 15%' "$home/.guard-err"; then
  pass "N2: a FRESH (30 s) v1.10.0 state window 200000 + claude-opus-5-5 at 150010 -> 15 % of 1M, silent"
else
  fail "N2: a fresh v1.10.0 state taken as is" "out=$(printf '%s' "$out" | head -c 200) dbg=$(cat "$home/.guard-err" 2>/dev/null)"
fi
# 8b2g. A future schema (state_version 3) is not a guess: a fresh state from
#       it is taken as is (75 % of its 200k), and a stale one still gives the
#       status line's window (200k beats the family rule), like version 2.
proj=$(mktempdir); home=$(mktempdir); tp="$home/w8g.jsonl"
mk_transcript "$tp" "claude-opus-5-5" 150010
seed_state "$home" "w8g" '{"pct": 75, "window": 200000, "input_tokens": 150010, "updated": @NOW@, "announced": 0, "state_version": 3}'
out=$(run_guard_dbg "$home" "$proj" "w8g" "$tp")
if printf '%s' "$out" | grep -q 'занято 75%'; then
  pass "N2: state_version 3 (a future schema) is trusted like 2 (fresh 75 % announced)"
else
  fail "N2: state_version 3 treated as a guess" "out=$out dbg=$(cat "$home/.guard-err" 2>/dev/null)"
fi
proj=$(mktempdir); home=$(mktempdir); tp="$home/w8h.jsonl"
mk_transcript "$tp" "claude-opus-5-5" 150010
seed_state "$home" "w8h" '{"pct": 70, "window": 200000, "input_tokens": 140000, "updated": 1000, "announced": 0, "state_version": 3}'
out=$(run_guard_dbg "$home" "$proj" "w8h" "$tp")
if grep -q 'окно 200000 (из состояния статус-строки)' "$home/.guard-err" && printf '%s' "$out" | grep -q 'занято 75%'; then
  pass "N2: a stale state_version 3 window 200000 is the status line's number (75 % of 200k)"
else
  fail "N2: stale state_version 3 treated as a guess" "out=$out dbg=$(cat "$home/.guard-err" 2>/dev/null)"
fi
# 8b4. A v1.10.0 state the guard DOES rewrite (the 60 % crossing of a 1M
#      family-5 model) is stored as version 2 with window_guess 1.
proj=$(mktempdir); home=$(mktempdir); tp="$home/w8m.jsonl"
mk_transcript "$tp" "claude-opus-5-5" 610000
seed_state "$home" "w8m" '{"pct": 75, "window": 200000, "input_tokens": 150010, "updated": 1000, "announced": 0}'
out=$(run_guard_dbg "$home" "$proj" "w8m" "$tp")
sf="$home/.claude/context-state/w8m.json"
if printf '%s' "$out" | grep -q 'занято 61%' && [ "$(state_field "$sf" window)" = "1000000" ] \
   && [ "$(state_field "$sf" window_guess)" = "1" ] && [ "$(state_field "$sf" state_version)" = "2" ]; then
  pass "N2: a rewritten v1.10.0 state is version 2 + window_guess 1 (61 % of 1M announced)"
else
  fail "N2: rewritten v1.10.0 state not marked as a guess" "out=$out state=$(cat "$sf" 2>/dev/null)"
fi
# 8b3. The status line writes state_version 2 (the mark 8b relies on).
proj=$(mktempdir); home=$(mktempdir)
run_statusline "$home" "$proj" "w8v" 10
if [ "$(state_field "$home/.claude/context-state/w8v.json" state_version)" = "2" ]; then
  pass "N2: the status line writes state_version 2"
else
  fail "N2: status-line state carries no state_version 2" "state=$(cat "$home/.claude/context-state/w8v.json" 2>/dev/null)"
fi
# 8c. The guard's own guess is marked: no state, claude-opus-5-5 at 160k ->
#     the state it writes carries window_guess 1 (so 8b cannot misfire on it).
proj=$(mktempdir); home=$(mktempdir); tp="$home/w8c.jsonl"
mk_transcript "$tp" "claude-opus-5-5" 450000
out=$(run_guard_dbg "$home" "$proj" "w8c" "$tp")
if printf '%s' "$out" | grep -q 'занято 45%' && [ "$(state_field "$home/.claude/context-state/w8c.json" window_guess)" = "1" ]; then
  pass "a window the guard guessed by model is stored with window_guess 1"
else
  fail "guessed window stored unmarked" "out=$out state=$(cat "$home/.claude/context-state/w8c.json" 2>/dev/null)"
fi

# 9. A last reply longer than the 200 KB tail (a big Write input or answer)
#    is cut before its `model` — the model is still found (a second, larger
#    tail reaches the record's start; Codex review P2). Without it: no model
#    -> the stale 200k state -> a false 80 %.
proj=$(mktempdir); home=$(mktempdir); tp="$home/w9.jsonl"
python3 - "$tp" <<'PYEOF'
import json, sys
row = {"type": "assistant", "message": {"model": "claude-opus-5-5", "id": "msg_big", "role": "assistant",
       "content": [{"type": "text", "text": "x" * 250000}],
       "usage": {"input_tokens": 160000, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}}}
with open(sys.argv[1], "w") as g:
    g.write(json.dumps({"type": "user", "message": {"role": "user", "content": "go"}}) + "\n")
    g.write(json.dumps(row, separators=(",", ":")) + "\n")
PYEOF
seed_state "$home" "w9" '{"pct": 50, "window": 200000, "input_tokens": 100000, "updated": 1000, "announced": 0, "window_guess": 1}'
out=$(run_guard_dbg "$home" "$proj" "w9" "$tp")
if [ -z "$out" ] && grep -q 'claude-opus-5-5' "$home/.guard-err" && grep -q 'окно 1000000' "$home/.guard-err"; then
  pass "a 250 KB last reply (model cut off the 200 KB tail) -> model still read, window 1M, silent"
else
  fail "model lost on a record longer than the tail" "out=$out dbg=$(cat "$home/.guard-err" 2>/dev/null)"
fi

# A sidechain reply (isSidechain: true — a subagent's record inside the main
# transcript) of another model after the main reply must not decide the window:
# the stale state says 200k, so taking claude-haiku-4-5 would read 160k as 80%.
proj=$(mktempdir); home=$(mktempdir); tp="$home/w10.jsonl"
mk_transcript "$tp" "claude-opus-5-5" 160000 '{"type":"assistant","isSidechain":true,"message":{"model":"claude-haiku-4-5-20251001","id":"msg_side","role":"assistant","content":[{"type":"text","text":"side"}]}}'
seed_state "$home" "w10" '{"pct": 50, "window": 200000, "input_tokens": 100000, "updated": 1000, "announced": 0, "window_guess": 1}'
out=$(run_guard_dbg "$home" "$proj" "w10" "$tp")
if [ -z "$out" ] && grep -q 'модель claude-opus-5-5' "$home/.guard-err" && grep -q 'окно 1000000' "$home/.guard-err"; then
  pass "a later isSidechain reply of claude-haiku-4-5 -> model stays claude-opus-5-5, window 1M, silent"
else
  fail "sidechain reply decided the model/window" "out=$out dbg=$(cat "$home/.guard-err" 2>/dev/null)"
fi

# ===========================================================================
group "T-154 subagents: no threshold directives (audit 02.10 Н1б / Н4а)"
# ===========================================================================
# A subagent's hook call carries `agent_id`; its own transcript lives in
# <dir>/<session_id>/subagents/agent-<id>.jsonl. A threshold directive told it
# to "сделай чекпоинт HANDOFF", which the rules do not allow a subagent (the
# task owner writes HANDOFF; autocheckpoint.sh skips agent-* on purpose) — 139
# of 146 subagents ignored it. Now: silence, and no state file of its own.
proj=$(mktempdir); home=$(mktempdir); sid="s154main"; aid="a0123456789abcdef"
main_tp="$home/proj-dir/$sid.jsonl"; sub_tp="$home/proj-dir/$sid/subagents/agent-$aid.jsonl"
mk_transcript "$main_tp" "claude-opus-5-5" 100000
mk_transcript "$sub_tp" "claude-opus-5-5" 900000
# 1. `agent_id` in the input with the PARENT's transcript path (the real input
#    shape): the parent's fresh state is at 85 % with announced=60. Without the
#    agent_id check the subagent would get the parent's "занято 85%" and eat
#    its announced (60 -> 80), so the parent would never hear zone 2.
seed_state "$home" "$sid" '{"pct": 85, "window": 1000000, "input_tokens": 850000, "updated": @NOW@, "announced": 60, "state_version": 2}'
out=$(run_guard_dbg "$home" "$proj" "$sid" "$main_tp" ",\"agent_id\":\"$aid\",\"agent_type\":\"pf-executor\"")
if [ "$(guard_rc "$home")" -eq 0 ] && [ -z "$out" ] && [ ! -f "$home/.claude/context-state/agent-$aid.json" ] \
   && [ "$(state_field "$home/.claude/context-state/$sid.json" announced)" = "60" ]; then
  pass "agent_id + parent transcript (parent at 85%, announced 60) -> empty output, parent's announced untouched, no agent state file"
else
  fail "subagent (agent_id) got a threshold directive or touched the parent's state" "rc=$(guard_rc "$home") out=$out announced=$(state_field "$home/.claude/context-state/$sid.json" announced) states=$(ls "$home/.claude/context-state" 2>/dev/null | tr '\n' ' ')"
fi
# 2. The other sign: the transcript path itself is a subagent's (no agent_id).
out=$(run_guard_dbg "$home" "$proj" "$sid" "$sub_tp")
if [ "$(guard_rc "$home")" -eq 0 ] && [ -z "$out" ]; then
  pass "transcript_path …/subagents/agent-*.jsonl without agent_id -> empty output"
else
  fail "subagent transcript path got a threshold directive" "rc=$(guard_rc "$home") out=$out"
fi
# 3. Negative control (green with the fix; red on main, which took 200k for
#    the `opus` alias -> 450%): the SAME 900k transcript as a
#    main session is announced — the silence is specific to subagents.
cp "$sub_tp" "$home/proj-dir/main2.jsonl"
out=$(run_guard_dbg "$home" "$proj" "main2" "$home/proj-dir/main2.jsonl")
if printf '%s' "$out" | grep -q 'занято 90%'; then
  pass "negative control: the same transcript as a main session -> 'занято 90%'"
else
  fail "negative control: main session at 90% not announced" "out=$out"
fi

# ===========================================================================
group "T-154 A1: snapshot on the first t2 crossing, even by a jump into zone 3 (audit 02.10 Н4б)"
# ===========================================================================
# The zone is picked top-down and the snapshot used to be written only in the
# zone-2 branch: a jump 35->95 or 55->95 (one big tool result) got the zone-3
# order "финальный pf-handoff pf-handoff" with no snapshot (Codex probe 22.09).
# A second snapshot of the same session/day OVERWRITES the same file, so the
# repeat cases delete the file first and check it is NOT re-created — counting
# files alone would pass even if the snapshot ran twice.
# step HOME PROJ SID PCT ANNOUNCED — a fresh status-line state at PCT of a 1M
# window, with the guard's ANNOUNCED carried over as statusline.sh keeps it;
# prints the guard's output.
step() {
  seed_state "$1" "$3" "{\"pct\": $4, \"window\": 1000000, \"input_tokens\": $(( $4 * 10000 )), \"updated\": @NOW@, \"announced\": $5, \"state_version\": 2}"
  run_guard "$1" "$2" "$3"
}
snaps() { local n=0 f; for f in "$1/.agents/runtime/handoff/"*.md; do [ -e "$f" ] && n=$((n+1)); done; echo "$n"; }
ann() { state_field "$1/.claude/context-state/$2.json" announced; }
# 1. 59 -> 95: one jump over t1 and t2 — the zone-3 order AND one snapshot.
proj=$(mktempdir); home=$(mktempdir); mkdir -p "$proj/.agents"
o1=$(step "$home" "$proj" a1 35 0)
o2=$(step "$home" "$proj" a1 95 "$(ann "$home" a1)")
if [ -z "$o1" ] && printf '%s' "$o2" | grep -q 'финальный pf-handoff' && printf '%s' "$o2" | grep -q 'Авто-снимок состояния записан сам' && [ "$(snaps "$proj")" = "1" ] && [ "$(ann "$home" a1)" = "75" ]; then
  pass "35% -> 95%: zone-3 order + exactly one snapshot (announced=75)"
else
  fail "35% -> 95%: no snapshot on the jump" "o1=$o1 | o2=$o2 | snaps=$(snaps "$proj") announced=$(ann "$home" a1)"
fi
# 2. Repeat 95 -> 96 after the jump: nothing said, no snapshot re-created.
rm -f "$proj/.agents/runtime/handoff/"*.md
o3=$(step "$home" "$proj" a1 96 "$(ann "$home" a1)")
if [ -z "$o3" ] && [ "$(snaps "$proj")" = "0" ]; then
  pass "repeat 95% -> 96%: silent, no second snapshot"
else
  fail "repeat after the jump wrote again" "o3=$o3 snaps=$(snaps "$proj")"
fi
# 3. 55 -> 95: t1 already announced (40), then a jump over t2 into zone 3.
proj=$(mktempdir); home=$(mktempdir); mkdir -p "$proj/.agents"
o1=$(step "$home" "$proj" a3 55 0)
o2=$(step "$home" "$proj" a3 95 "$(ann "$home" a3)")
if printf '%s' "$o1" | grep -q 'чекпоинт HANDOFF' && printf '%s' "$o2" | grep -q 'финальный pf-handoff' && printf '%s' "$o2" | grep -q 'Авто-снимок состояния записан сам' && [ "$(snaps "$proj")" = "1" ]; then
  pass "55% -> 95%: zone 1 first, then zone-3 order + exactly one snapshot"
else
  fail "55% -> 95%: no snapshot on the jump" "o1=$o1 | o2=$o2 | snaps=$(snaps "$proj")"
fi
# 4. The ordinary path is unchanged (green before and after): 55 -> 65 gives
#    zone 2 + the snapshot; 85 -> 95 afterwards gives the zone-3 order and NO
#    second snapshot — t2 was already crossed and saved.
proj=$(mktempdir); home=$(mktempdir); mkdir -p "$proj/.agents"
o1=$(step "$home" "$proj" a4 55 0)
o2=$(step "$home" "$proj" a4 65 "$(ann "$home" a4)")
n2=$(snaps "$proj"); rm -f "$proj/.agents/runtime/handoff/"*.md
o3=$(step "$home" "$proj" a4 95 "$(ann "$home" a4)")
if printf '%s' "$o2" | grep -q 'новых M/L не начинать' && printf '%s' "$o2" | grep -q 'Авто-снимок состояния записан сам' && [ "$n2" = "1" ] \
   && printf '%s' "$o3" | grep -q 'финальный pf-handoff' && ! printf '%s' "$o3" | grep -q 'Авто-снимок' && [ "$(snaps "$proj")" = "0" ]; then
  pass "55% -> 65% -> 95%: zone 2 + one snapshot as before; zone 3 afterwards adds no second snapshot"
else
  fail "ordinary t2 path changed" "o2=$o2 | n2=$n2 | o3=$o3 | snaps=$(snaps "$proj")"
fi
# 5. A failed snapshot on the jump is loud: the zone-3 order carries
#    «НЕ УДАЛОСЬ» (forced with chmod 555 on both write targets, as in
#    threshold-parity.sh; as root chmod cannot force it — reported, not passed).
if [ "$(id -u)" = "0" ]; then
  fail "A1 failure case skipped: running as root, chmod 555 cannot force a write failure"
else
  proj=$(mktempdir); home=$(mktempdir)
  mkdir -p "$proj/.agents/runtime/handoff" "$home/.claude/context-state/handoff"
  chmod 555 "$proj/.agents/runtime/handoff" "$home/.claude/context-state/handoff"
  o=$(step "$home" "$proj" a5 95 0)
  chmod 755 "$proj/.agents/runtime/handoff" "$home/.claude/context-state/handoff" 2>/dev/null
  if printf '%s' "$o" | grep -q 'финальный pf-handoff' && printf '%s' "$o" | grep -q 'НЕ УДАЛОСЬ'; then
    pass "jump to 95% with both snapshot targets unwritable -> the order says the snapshot FAILED"
  else
    fail "failed snapshot on the jump not reported" "o=$o"
  fi
fi
# 6. The same jump in a session WITHOUT a status line (Claude desktop): no
#    state at all, the guard reads the transcript — 35% then 95%.
proj=$(mktempdir); home=$(mktempdir); mkdir -p "$proj/.agents"; tp="$home/a6.jsonl"
mk_transcript "$tp" "claude-opus-5-5" 350000
o1=$(run_guard_dbg "$home" "$proj" a6 "$tp")
mk_transcript "$tp" "claude-opus-5-5" 950000
o2=$(run_guard_dbg "$home" "$proj" a6 "$tp")
if [ -z "$o1" ] && printf '%s' "$o2" | grep -q 'занято 95%' && printf '%s' "$o2" | grep -q 'Авто-снимок состояния записан сам' && [ "$(snaps "$proj")" = "1" ]; then
  pass "no status line (transcript only): 35% -> 95% -> zone-3 order + one snapshot"
else
  fail "transcript-only jump: no snapshot" "o1=$o1 | o2=$o2 | snaps=$(snaps "$proj")"
fi

# ===========================================================================
group "sessionstart (T-165): «Прочитай HANDOFF» after compact/resume, a list on startup (QA Y3) + wait list from the registry"
# ===========================================================================
# ss_proj DIR TABLE-FILE — a project with AGENTS.md and one active HANDOFF
# whose body is TABLE-FILE (may be empty). Prints nothing.
ss_proj() {
  local d="$1" body="$2"
  mkdir -p "$d/.agents/runtime/handoff"; touch "$d/AGENTS.md"
  { printf -- '---\nstatus: active\nsession_id: sess-0001\ntask: T-999\n---\n# HANDOFF\n\n'; cat "$body"; } > "$d/.agents/runtime/handoff/2026-10-09-x.md"
}
# ss_out HOME PROJ SOURCE SID — the hook's additionalContext (all lines); rc kept in SS_RC.
SS_RC=0
ss_out() {
  local out
  out=$(printf '{"source":"%s","cwd":"%s","session_id":"%s"}' "$3" "$2" "$4" | HOME="$1" "$BASH_BIN" "$SESSIONSTART" 2>/dev/null); SS_RC=$?
  [ -n "$out" ] && printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])'
}
REG=$(mktempdir)/reg.md
cat > "$REG" <<'EOT'
| Задание | Тикеты | Субагент | Статус |
|---|---|---|---|
| B | T-998 | a1b2c3 | запущен 20:10 |
| A | T-997 | d4e5f6 | done |
| C | T-996 | g7h8i9 | НЕ запущен |
| D | T-995 | j1k2l3 | перезапущен 21:00 \| ждёт B |
| E | T-994 | m4n5o6 | запущен |
EOT
EMPTY=$(mktempdir)/empty.md; : > "$EMPTY"
proj=$(mktempdir); home=$(mktempdir); ss_proj "$proj" "$REG"
printf '2026-10-09T20:00 sess-0001-s1 manual\n' > "$(mkdir -p "$home/.claude/context-state"; echo "$home/.claude/context-state/compacts.log")"
for case_src in "compact:sess-0001-s1" "compact:sess-0001-s2" "startup:sess-0001-s3" "resume:sess-0001-s4"; do
  src=${case_src%%:*}; sid=${case_src##*:}
  o=$(ss_out "$home" "$proj" "$src" "$sid"); first=$(printf '%s\n' "$o" | head -n 1)
  label="$src ($sid$([ "$sid" = sess-0001-s1 ] && echo ', manual compact log'))"
  if [ "$src" = startup ]; then
    # QA 2.0.0 Y3: on a fresh startup only a list entry with the pointer — no «продолжи».
    if [ "$SS_RC" = 0 ] && printf '%s' "$first" | grep -q '^Активный HANDOFF .*2026-10-09-x\.md — /pf-resume 2026-10-09-x (источник: startup' \
       && ! printf '%s' "$o" | grep -q 'и продолжи'; then
      pass "$label: line 1 = «Активный HANDOFF <path> — /pf-resume <slug>», no «продолжи»"
    else
      fail "$label: wrong first line" "rc=$SS_RC first=$first"
    fi
  elif [ "$SS_RC" = 0 ] && printf '%s' "$first" | grep -q '^Прочитай HANDOFF .*2026-10-09-x\.md и продолжи'; then
    pass "$label: line 1 = «Прочитай HANDOFF <path> и продолжи»"
  else
    fail "$label: wrong first line" "rc=$SS_RC first=$first"
  fi
  # wait list: B (запущен), D (перезапущен, escaped pipe) and E (last-column «Статус») yes; A done and C «НЕ запущен» no.
  # T-168: on startup the list is «Запущены по реестру прошлой сессии: …» (check, don't wait blindly), not «Ты ждёшь».
  if [ "$src" = startup ]; then wait_re='Запущены по реестру прошлой сессии:'; else wait_re='Ты ждёшь:'; fi
  if printf '%s' "$first" | grep -qF "$wait_re" && printf '%s' "$first" | grep -q 'a1b2c3' \
     && printf '%s' "$first" | grep -q 'j1k2l3' && printf '%s' "$first" | grep -q 'm4n5o6' \
     && ! printf '%s' "$first" | grep -qE 'd4e5f6|g7h8i9'; then
    pass "$label: wait list = running rows only (запущен, перезапущен with \\|), not done / НЕ запущен"
  else
    fail "$label: wait list wrong" "first=$first"
  fi
done
# Exactly three entries on the first line (B, D, E).
o=$(ss_out "$home" "$proj" compact sess-0001-s2); n=$(printf '%s\n' "$o" | head -n 1 | sed 's/.*Ты ждёшь: //' | awk -F'; ' '{print NF}')
[ "$n" = 3 ] && pass "wait list has exactly 3 entries" || fail "wait list entry count" "n=$n o=$o"
# Old behaviour is gone.
if ! printf '%s' "$o" | grep -qE 'из сводки компакта|Компакт выполнен вручную|/pf-resume'; then
  pass "no «перенеси из сводки» and no «Компакт выполнен вручную» branch"
else
  fail "old compact text still printed" "o=$o"
fi
# Only done / НЕ запущен rows -> first line, no «Ты ждёшь».
printf '| Задание | Субагент | Статус |\n|---|---|---|\n| A | d4e5f6 | done |\n| C | g7h8i9 | НЕ запущен |\n' > "$REG.2"
proj=$(mktempdir); ss_proj "$proj" "$REG.2"
o=$(ss_out "$home" "$proj" compact sess-0001-s5)
if [ "$SS_RC" = 0 ] && printf '%s' "$o" | head -n 1 | grep -q '^Прочитай HANDOFF ' && ! printf '%s' "$o" | grep -qi 'ждёшь'; then
  pass "registry without running rows: «Прочитай HANDOFF» present, no wait list"
else
  fail "registry without running rows" "o=$o"
fi
# HANDOFF without a table.
proj=$(mktempdir); printf 'Просто текст без таблицы. запущен субагент\n' > "$REG.3"; ss_proj "$proj" "$REG.3"
o=$(ss_out "$home" "$proj" startup s6)
if printf '%s' "$o" | head -n 1 | grep -q '^Активный HANDOFF ' && ! printf '%s' "$o" | grep -qiE 'ждёшь|Запущены'; then
  pass "HANDOFF without a table: the HANDOFF line present, no wait list"
else
  fail "HANDOFF without a table" "o=$o"
fi
# No HANDOFF at all: only the session line (QA Ж-5), rc 0.
proj=$(mktempdir); mkdir -p "$proj/.agents"; o=$(ss_out "$home" "$proj" compact s7)
[ "$o" = "Сессия: s7 — это значение поля session_id в HANDOFF/реестре." ] && [ "$SS_RC" = 0 ] && pass "no HANDOFF: only the session line, rc 0" || fail "no HANDOFF: unexpected output" "rc=$SS_RC o=$o"
# Three active HANDOFFs: newest in the first line, the others below.
proj=$(mktempdir); ss_proj "$proj" "$EMPTY"
printf -- '---\nstatus: active\n---\n' > "$proj/.agents/runtime/handoff/2026-10-08-y.md"
touch -t 202610081000 "$proj/.agents/runtime/handoff/2026-10-08-y.md" 2>/dev/null
o=$(ss_out "$home" "$proj" resume sess-0001-s8)
if printf '%s' "$o" | head -n 1 | grep -q '2026-10-09-x\.md' && printf '%s' "$o" | sed -n '2,$p' | grep -q 'Ещё активный HANDOFF: .*2026-10-08-y\.md'; then
  pass "two active HANDOFFs: newest on line 1, the other below"
else
  fail "multi-HANDOFF layout" "o=$o"
fi
# «cwd не проект» comes AFTER line 1 when both exist (HANDOFF dir without AGENTS.md/.agents is impossible,
# so the order is checked on the builder level: warn is never the first line when a HANDOFF line exists).
if grep -n 'context_lines="\$context_lines' "$SESSIONSTART" | grep -q . && ! grep -q 'context_lines="\$warn' "$SESSIONSTART"; then
  pass "«cwd не проект» is appended after the HANDOFF line (source check)"
else
  fail "warn is still prepended"
fi
# --- fix round 1 (review 10.10) ---------------------------------------------
# (a) «Статус» in the MIDDLE: the subagent id (after the status column) must be
# in the list; (b) a really shifted row (cell count != header); (c) the status
# column is found by its header, not taken as the last cell.
MID=$(mktempdir)/mid.md
cat > "$MID" <<'EOT'
| Задание | Статус | Субагент | Заметка |
|---|---|---|---|
| A2 | запущен 10:00 | a2a2a2 | ok |
| D2 | done | d2d2d2 | x |
| N2 | НЕ запущен | n2n2n2 | x |
| S2 | запущен | s2s2s2 | note | extra |
EOT
proj=$(mktempdir); ss_proj "$proj" "$MID"
first=$(ss_out "$home" "$proj" compact sess-0001-m1 | head -n 1)
if printf '%s' "$first" | grep -q 'A2 .*a2a2a2' && printf '%s' "$first" | grep -q 's2s2s2' \
   && ! printf '%s' "$first" | grep -qE 'd2d2d2|n2n2n2'; then
  pass "«Статус» in the middle: id after the status column is in the list (a); shifted row is checked and listed (b); header-found column (c)"
else
  fail "mid-table status column" "first=$first"
fi
# Own HANDOFF by session_id (compact/resume); a fresher foreign HANDOFF is not ours.
proj=$(mktempdir); mkdir -p "$proj/.agents/runtime/handoff"; touch "$proj/AGENTS.md"
printf -- '---\nstatus: active\nsession_id: aaaaaaaa-1111  # моя\n---\n| Задание | Субагент | Статус |\n|---|---|---|\n| OWN | own111 | запущен |\n' > "$proj/.agents/runtime/handoff/own.md"
printf -- '---\nstatus: active\nsession_id: bbbbbbbb-2222\n---\n| Задание | Субагент | Статус |\n|---|---|---|\n| FOREIGN | for222 | запущен |\n' > "$proj/.agents/runtime/handoff/foreign.md"
touch -t 202610091000 "$proj/.agents/runtime/handoff/own.md"
for src in compact resume; do
  o=$(ss_out "$home" "$proj" "$src" aaaaaaaa-1111-full); first=$(printf '%s\n' "$o" | head -n 1)
  if printf '%s' "$first" | grep -q 'handoff/own\.md' && printf '%s' "$first" | grep -q 'own111' \
     && ! printf '%s' "$first" | grep -q 'for222' && printf '%s' "$o" | sed -n '2,$p' | grep -q 'foreign\.md'; then
    pass "$src: own HANDOFF (session_id, comment after value) first with own ids; fresher foreign one only below"
  else
    fail "$src: own HANDOFF not preferred" "o=$o"
  fi
done
# No own HANDOFF: newest active, but no wait list (foreign subagents).
o=$(ss_out "$home" "$proj" compact zzzzzzzz-9999); first=$(printf '%s\n' "$o" | head -n 1)
if printf '%s' "$first" | grep -q 'foreign\.md' && ! printf '%s' "$first" | grep -qi 'ждёшь'; then
  pass "compact without own HANDOFF: newest active, no «Ты ждёшь»"
else
  fail "compact without own HANDOFF" "o=$o"
fi
# startup: newest active with its list (T-168: worded «Запущены по реестру …», see the clear group).
o=$(ss_out "$home" "$proj" startup aaaaaaaa-1111-full); first=$(printf '%s\n' "$o" | head -n 1)
if printf '%s' "$first" | grep -q 'foreign\.md' && printf '%s' "$first" | grep -q 'for222'; then
  pass "startup: newest active HANDOFF + its list"
else
  fail "startup selection changed" "o=$o"
fi
# Fix round 2: a HANDOFF without session_id (field missing or «—», the pf-handoff
# template default) is NOT foreign — it keeps its wait list after compact/resume.
NOSID=$(mktempdir)/nosid.md
printf '| Задание | Субагент | Статус |\n|---|---|---|\n| W | w1w1w1 | запущен |\n' > "$NOSID"
for variant in dash missing; do
  proj=$(mktempdir); mkdir -p "$proj/.agents/runtime/handoff"; touch "$proj/AGENTS.md"
  if [ "$variant" = dash ]; then hdr='session_id: —'; else hdr='task: T-1'; fi
  { printf -- '---\nstatus: active\n%s\n---\n' "$hdr"; cat "$NOSID"; } > "$proj/.agents/runtime/handoff/n.md"
  first=$(ss_out "$home" "$proj" compact sess-0001-n | head -n 1)
  if printf '%s' "$first" | grep -q 'Ты ждёшь:.*w1w1w1'; then
    pass "session_id $variant: HANDOFF stays a candidate, wait list present after compact"
  else
    fail "session_id $variant lost the wait list" "first=$first"
  fi
done
# Order: own > newest without session_id (with list) > newest foreign (no list).
proj=$(mktempdir); mkdir -p "$proj/.agents/runtime/handoff"; touch "$proj/AGENTS.md"
{ printf -- '---\nstatus: active\nsession_id: —\n---\n'; cat "$NOSID"; } > "$proj/.agents/runtime/handoff/nosid.md"
{ printf -- '---\nstatus: active\nsession_id: bbbbbbbb-2222\n---\n| Задание | Субагент | Статус |\n|---|---|---|\n| F | f2f2f2 | запущен |\n'; } > "$proj/.agents/runtime/handoff/foreign.md"
touch -t 202610091000 "$proj/.agents/runtime/handoff/nosid.md"
first=$(ss_out "$home" "$proj" compact aaaaaaaa-1111 | head -n 1)
if printf '%s' "$first" | grep -q 'nosid\.md' && printf '%s' "$first" | grep -q 'w1w1w1' && ! printf '%s' "$first" | grep -q 'f2f2f2'; then
  pass "no own HANDOFF: older one without session_id beats a fresher foreign one, with its list"
else
  fail "order own > no-session_id > foreign" "first=$first"
fi
# Prefix length: a file id shorter than 8 chars that merely starts the session id is NOT ours.
proj=$(mktempdir); mkdir -p "$proj/.agents/runtime/handoff"; touch "$proj/AGENTS.md"
{ printf -- '---\nstatus: active\nsession_id: abc\n---\n'; cat "$NOSID"; } > "$proj/.agents/runtime/handoff/short.md"
first=$(ss_out "$home" "$proj" compact abcdef12-3456 | head -n 1)
if printf '%s' "$first" | grep -q 'short\.md' && ! printf '%s' "$first" | grep -qi 'ждёшь'; then
  pass "session_id shorter than 8 chars matching only by prefix is foreign: no wait list"
else
  fail "short id prefix treated as own" "first=$first"
fi
# Garbage / empty / broken inputs never break the session.
bad_ok=1
for inp in '' 'not json' '{"source":"compact"}' '{"source":"compact","cwd":"/nonexistent/zz","session_id":"s"}'; do
  printf '%s' "$inp" | HOME="$home" "$BASH_BIN" "$SESSIONSTART" >/dev/null 2>&1 || bad_ok=0
done
proj=$(mktempdir); mkdir -p "$proj/.agents/runtime/handoff"
printf -- '---\nstatus: active\ntask: T-1\n| Задание | Статус |\n|---|---|\n| a | b | c | запущен\n| \\\n' > "$proj/.agents/runtime/handoff/z.md"
o=$(ss_out "$home" "$proj" compact s9); [ "$SS_RC" = 0 ] || bad_ok=0
[ "$bad_ok" = 1 ] && pass "garbage stdin, empty stdin, unknown cwd, broken HANDOFF (no closing ---, skewed table): rc 0" || fail "hook failed on bad input" "rc=$SS_RC"
# python3 unavailable: first line stays, the list is silently skipped (needs jq for the JSON in/out).
if command -v jq >/dev/null 2>&1; then
  shim=$(mktempdir); printf '#!/bin/sh\nexit 127\n' > "$shim/python3"; chmod +x "$shim/python3"
  proj=$(mktempdir); ss_proj "$proj" "$REG"
  o=$(printf '{"source":"compact","cwd":"%s","session_id":"sess-0001-s10"}' "$proj" | HOME="$home" PATH="$shim:$PATH" "$BASH_BIN" "$SESSIONSTART" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext' | head -n 1)
  if printf '%s' "$o" | grep -q '^Прочитай HANDOFF ' && ! printf '%s' "$o" | grep -qi 'ждёшь'; then
    pass "python3 unavailable: «Прочитай HANDOFF» stays, wait list silently skipped"
  else
    fail "python3-less run" "o=$o"
  fi
else
  fail "python3-less case skipped: jq is not installed (the hook needs one of jq/python3 for JSON)"
fi

# ===========================================================================
group "sessionstart clear (T-168): /clear -> pointer «/pf-resume <slug>»; startup list is «сверь», not «Ты ждёшь»"
# ===========================================================================
# clear: one pointer line with the slug, no «Прочитай … и продолжи», no wait list.
proj=$(mktempdir); ss_proj "$proj" "$REG"
o=$(ss_out "$home" "$proj" clear c1); first=$(printf '%s\n' "$o" | head -n 1)
if [ "$SS_RC" = 0 ] && printf '%s' "$first" | grep -q '^Активный HANDOFF .*2026-10-09-x\.md — /pf-resume 2026-10-09-x ' \
   && ! printf '%s' "$o" | grep -qE 'и продолжи|ждёшь|Запущены по реестру'; then
  pass "clear: «Активный HANDOFF <path> — /pf-resume <slug>», no «продолжи», no wait list"
else
  fail "clear pointer" "rc=$SS_RC o=$o"
fi
# clear without an active HANDOFF: silent, rc 0.
proj=$(mktempdir); mkdir -p "$proj/.agents/runtime/handoff"; touch "$proj/AGENTS.md"
printf -- '---\nstatus: closed\n---\n' > "$proj/.agents/runtime/handoff/2026-10-09-c.md"
o=$(ss_out "$home" "$proj" clear c2)
[ "$o" = "Сессия: c2 — это значение поля session_id в HANDOFF/реестре." ] && [ "$SS_RC" = 0 ] && pass "clear, only a closed HANDOFF: only the session line, rc 0" || fail "clear without active HANDOFF: unexpected output" "rc=$SS_RC o=$o"
# clear shares the compact/resume pick: a HANDOFF without session_id beats a fresher foreign one.
proj=$(mktempdir); mkdir -p "$proj/.agents/runtime/handoff"; touch "$proj/AGENTS.md"
printf -- '---\nstatus: active\nsession_id: —\n---\n' > "$proj/.agents/runtime/handoff/nosid.md"
printf -- '---\nstatus: active\nsession_id: bbbbbbbb-2222\n---\n' > "$proj/.agents/runtime/handoff/foreign.md"
touch -t 202610091000 "$proj/.agents/runtime/handoff/nosid.md"
first=$(ss_out "$home" "$proj" clear new-sess-1 | head -n 1)
if printf '%s' "$first" | grep -q '/pf-resume nosid '; then
  pass "clear: pick order own > no session_id > foreign (shared with compact/resume)"
else
  fail "clear pick order" "first=$first"
fi
# startup with running rows (fix round 1): «Запущены по реестру прошлой сессии: …» + how to check
# detached processes (council.sh --wait / kill -0); never «Ты ждёшь», never a bare «не жди».
STARTUP_HINT='Субагенты закрытой сессии не вернутся — сверь статусы пакетов; маркер или PID council проверь через `council.sh --wait` / `kill -0`; чужие задания не перезапускай.'
proj=$(mktempdir); ss_proj "$proj" "$REG"
o=$(ss_out "$home" "$proj" startup sess-0001-st); first=$(printf '%s\n' "$o" | head -n 1)
if printf '%s' "$first" | grep -qF 'Запущены по реестру прошлой сессии: ' && printf '%s' "$first" | grep -q 'a1b2c3' \
   && printf '%s' "$first" | grep -qF "$STARTUP_HINT" && ! printf '%s' "$o" | grep -qE 'ждёшь|не жди|другой сессии'; then
  pass "startup (own / no session_id): «Запущены по реестру…» + council.sh --wait / kill -0 hint, no «Ты ждёшь», no «не жди», no foreign suffix"
else
  fail "startup wording" "first=$first"
fi
# HANDOFF without session_id («—»): not foreign -> no suffix.
proj=$(mktempdir); mkdir -p "$proj/.agents/runtime/handoff"; touch "$proj/AGENTS.md"
{ printf -- '---\nstatus: active\nsession_id: —\n---\n'; cat "$REG"; } > "$proj/.agents/runtime/handoff/d.md"
first=$(ss_out "$home" "$proj" startup new-sess-3 | head -n 1)
if printf '%s' "$first" | grep -qF "$STARTUP_HINT" && ! printf '%s' "$first" | grep -q 'другой сессии'; then
  pass "startup, HANDOFF with session_id «—»: hint without the foreign-session suffix"
else
  fail "startup session_id «—»" "first=$first"
fi
# startup, HANDOFF with a foreign session_id: the same line ends with the «другой сессии» suffix.
proj=$(mktempdir); ss_proj "$proj" "$REG"
first=$(ss_out "$home" "$proj" startup new-sess-2 | head -n 1)
if printf '%s' "$first" | grep -qF "$STARTUP_HINT (HANDOFF другой сессии — она может быть жива)" \
   && printf '%s' "$first" | grep -q 'a1b2c3'; then
  pass "startup, foreign session_id: line ends with «(HANDOFF другой сессии — она может быть жива)»"
else
  fail "startup foreign suffix" "first=$first"
fi
# compact and resume keep «Ты ждёшь».
for src in compact resume; do
  first=$(ss_out "$home" "$proj" "$src" sess-0001-k | head -n 1)
  if printf '%s' "$first" | grep -q 'Ты ждёшь: .*a1b2c3' && ! printf '%s' "$first" | grep -qE 'Запущены по реестру|другой сессии'; then
    pass "$src: «Ты ждёшь» kept"
  else
    fail "$src lost «Ты ждёшь»" "first=$first"
  fi
done

# ===========================================================================
group "QA 2.0.0: fields from the HANDOFF are clipped (Y3), session line (Ж-5), quiet council children"
# ===========================================================================
# A 300-char Cyrillic task and registry cell: each reaches the context as at
# most 120 characters (valid UTF-8 — cut by characters, not bytes).
proj=$(mktempdir); mkdir -p "$proj/.agents/runtime/handoff"; touch "$proj/AGENTS.md"
LONG=$(python3 -c 'print("Ж" * 300)')
printf -- '---\nstatus: active\nsession_id: —\ntask: %s\n---\n| Задание | Статус |\n|---|---|\n| %s | запущен |\n' "$LONG" "$LONG" > "$proj/.agents/runtime/handoff/long.md"
for src in startup compact; do
  o=$(ss_out "$home" "$proj" "$src" sess-clip-1)
  runs=$(printf '%s' "$o" | python3 -c 'import re,sys; print(max(len(m) for m in re.findall("Ж+", sys.stdin.read())))')
  if [ "$runs" -le 120 ] && [ "$runs" -ge 100 ] && printf '%s' "$o" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
    pass "$src: task and registry cell clipped to <= 120 characters (longest run $runs), valid UTF-8"
  else
    fail "$src: field from the HANDOFF not clipped" "runs=$runs"
  fi
done
# Session line: first 8 characters of the hook input's session_id, last line, on every source.
for src in startup resume compact clear; do
  last=$(ss_out "$home" "$proj" "$src" "abcdef12-3456-7890" | tail -n 1)
  if [ "$last" = "Сессия: abcdef12 — это значение поля session_id в HANDOFF/реестре." ]; then
    pass "$src: last line = «Сессия: abcdef12 — …»"
  else
    fail "$src: session line missing" "last=$last"
  fi
done
# PF_COUNCIL_RUN=1 (a council.sh child CLI): the four hooks print nothing,
# rc 0, no snapshot — with a control run without the variable that does talk.
qhome=$(mktempdir); qproj=$(mktempdir); mkdir -p "$qproj/.agents/runtime/handoff"; touch "$qproj/AGENTS.md"
printf -- '---\nstatus: active\n---\n' > "$qproj/.agents/runtime/handoff/q.md"
qtp="$qhome/q.jsonl"; mk_transcript "$qtp" "claude-opus-5-5" 950000
q_ss='{"source":"compact","cwd":"'"$qproj"'","session_id":"qsess001"}'
q_gd='{"session_id":"qsess002","hook_event_name":"UserPromptSubmit","transcript_path":"'"$qtp"'","cwd":"'"$qproj"'"}'
q_pc='{"session_id":"qsess003","hook_event_name":"PreCompact","trigger":"auto","transcript_path":"'"$qtp"'","cwd":"'"$qproj"'"}'
q_sl='{"session_id":"qsess004","context_window":{"used_percentage":30,"context_window_size":1000000,"total_input_tokens":300000},"cwd":"'"$qproj"'"}'
n_auto() { local n=0 f; for f in "$1"/*auto*; do [ -e "$f" ] && n=$((n + 1)); done; echo "$n"; }
for pair in "sessionstart:$SESSIONSTART:$q_ss" "context-guard:$GUARD:$q_gd" "precompact:$PRECOMPACT:$q_pc" "statusline:$STATUSLINE:$q_sl"; do
  name=${pair%%:*}; rest=${pair#*:}; script=${rest%%:*}; payload=${rest#*:}
  q_snap_before=$(n_auto "$qproj/.agents/runtime/handoff")
  q_on=$(printf '%s' "$payload" | PF_COUNCIL_RUN=1 HOME="$qhome" CONTEXT_HOOKS_ORCA_STATUSLINE=/nonexistent "$BASH_BIN" "$script" 2>&1); q_rc=$?
  q_snap_on=$(( $(n_auto "$qproj/.agents/runtime/handoff") - q_snap_before ))
  q_off=$(printf '%s' "$payload" | HOME="$qhome" CONTEXT_HOOKS_ORCA_STATUSLINE=/nonexistent PF_STATUSLINE_CONFIG=/nonexistent "$BASH_BIN" "$script" 2>/dev/null)
  # precompact.sh says nothing on success — its control is the snapshot file.
  if [ "$name" = precompact ]; then q_off=""; for f in "$qproj"/.agents/runtime/handoff/*auto-qsess003*; do [ -e "$f" ] && q_off="$f"; done; fi
  if [ "$q_rc" = 0 ] && [ -z "$q_on" ] && [ "$q_snap_on" = 0 ] && [ -n "$q_off" ]; then
    pass "PF_COUNCIL_RUN=1: $name prints nothing, writes no snapshot, rc 0 (control without the variable does)"
  else
    fail "PF_COUNCIL_RUN=1: $name not quiet (or the control is silent)" "rc=$q_rc on=$q_on off=$(printf '%s' "$q_off" | head -c 200)"
  fi
done

# Y4: the snapshot hook creates the project's HANDOFF directory with a
# .gitignore that ignores everything but itself. N3: an EXISTING directory
# without one (every project that ran v1.10.0) gets it too; an existing
# .gitignore is kept, and a symlink in its place is not written through.
if command -v git >/dev/null 2>&1; then
  gproj=$(mktempdir); mkdir -p "$gproj/.agents"; git -C "$gproj" init -q
  printf '{"session_id":"gsess001","hook_event_name":"PreCompact","trigger":"manual","cwd":"%s"}' "$gproj" | HOME="$(mktempdir)" "$BASH_BIN" "$PRECOMPACT" >/dev/null 2>&1
  g_untracked=$(git -C "$gproj" ls-files -o --exclude-standard)
  snapf=$(ls "$gproj/.agents/runtime/handoff/"*auto* 2>/dev/null | head -1)
  if [ "$g_untracked" = ".agents/runtime/handoff/.gitignore" ] && [ -n "$snapf" ] && git -C "$gproj" check-ignore -q "$snapf"; then
    pass "Y4: fresh .agents/runtime/handoff gets a self-ignoring .gitignore; the snapshot is git-ignored"
  else
    fail "Y4: snapshot directory not git-ignored" "untracked=$g_untracked snap=$snapf"
  fi
  gproj2=$(mktempdir); mkdir -p "$gproj2/.agents/runtime/handoff"; git -C "$gproj2" init -q
  printf '{"session_id":"gsess002","hook_event_name":"PreCompact","trigger":"auto","cwd":"%s"}' "$gproj2" | HOME="$(mktempdir)" "$BASH_BIN" "$PRECOMPACT" >/dev/null 2>&1
  git -C "$gproj2" add -A 2>/dev/null
  g_staged=$(git -C "$gproj2" diff --cached --name-only)
  if [ "$g_staged" = ".agents/runtime/handoff/.gitignore" ] && ls "$gproj2/.agents/runtime/handoff/"*auto* >/dev/null 2>&1; then
    pass "N3: an existing HANDOFF directory without .gitignore gets one; git add -A stages only the .gitignore, not the snapshot"
  else
    fail "N3: snapshot in an existing HANDOFF directory goes into git add -A" "staged=$g_staged"
  fi
  gproj3=$(mktempdir); mkdir -p "$gproj3/.agents/runtime/handoff"; printf 'mine\n' > "$gproj3/.agents/runtime/handoff/.gitignore"
  gproj4=$(mktempdir); mkdir -p "$gproj4/.agents/runtime/handoff"; ln -s "$gproj4/victim" "$gproj4/.agents/runtime/handoff/.gitignore"
  for gp in "$gproj3" "$gproj4"; do
    printf '{"session_id":"gsess003","hook_event_name":"PreCompact","trigger":"manual","cwd":"%s"}' "$gp" | HOME="$(mktempdir)" "$BASH_BIN" "$PRECOMPACT" >/dev/null 2>&1
  done
  if [ "$(cat "$gproj3/.agents/runtime/handoff/.gitignore")" = "mine" ] && [ ! -e "$gproj4/victim" ]; then
    pass "N3: an existing .gitignore is kept as is; a dangling symlink in its place is not written through"
  else
    fail "N3: existing .gitignore overwritten or symlink followed" "g3=$(cat "$gproj3/.agents/runtime/handoff/.gitignore") victim=$(ls "$gproj4" 2>&1)"
  fi
else
  fail "Y4 case skipped: git is not installed"
fi

# ===========================================================================
group "foreign input (T-166): unknown platform or format -> rc 0, empty stdout"
# ===========================================================================
# Rule of SPEC-workflow-v3 sec. 4: a hook that does not recognise its input
# exits 0 with no output. Grok runs the hooks of ~/.claude/settings.json with
# camelCase JSON (sessionId, hookEventName, transcriptPath -> its own
# updates.jsonl); Codex sends snake_case, but its transcript is a rollout file.
# precompact.sh used to return 2 on garbage and on Grok input — it blocked
# the compaction of a foreign platform.
AUTOCKPT="$HOOKS_DIR/autocheckpoint.sh"
fhome=$(mktempdir); fproj=$(mktempdir); mkdir -p "$fproj/.agents"
F_GROK=$(printf '{"sessionId":"g1","hookEventName":"PreCompact","trigger":"auto","transcriptPath":"%s/updates.jsonl","cwd":"%s"}' "$fproj" "$fproj")
# foreign_case LABEL HOOK INPUT — rc 0 and empty stdout, or FAIL with both.
foreign_case() {
  local label="$1" hook="$2" inp="$3" out rc
  out=$(printf '%s' "$inp" | HOME="$fhome" CLAUDE_SETTINGS_PATH=/nonexistent-guard-cases-settings.json \
        PF_STATUSLINE_CONFIG=/nonexistent-guard-cases-cfg.json CONTEXT_HOOKS_ORCA_STATUSLINE=/nonexistent-orca.sh \
        "$BASH_BIN" "$hook" 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "foreign: $label -> rc 0, empty stdout"
  else
    fail "foreign: $label" "rc=$rc out=$out"
  fi
}
for h in context-guard sessionstart precompact statusline autocheckpoint; do
  case "$h" in autocheckpoint) hp="$AUTOCKPT" ;; *) hp="$HOOKS_DIR/$h.sh" ;; esac
  foreign_case "$h.sh, empty stdin" "$hp" ''
  foreign_case "$h.sh, garbage{" "$hp" 'garbage{'
  foreign_case "$h.sh, Grok camelCase" "$hp" "$F_GROK"
done
# Codex: snake_case like Claude, but the transcript is a rollout.
mkdir -p "$fproj/codex"
{
  printf '%s\n' '{"timestamp":"2026-10-10T10:00:00Z","type":"session_meta","payload":{"id":"cx-1","cwd":"/tmp","originator":"codex_cli_rs"}}'
  printf '%s\n' '{"timestamp":"2026-10-10T10:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":900000,"output_tokens":10},"model_context_window":1000000}}}'
  printf '%s\n' '{"timestamp":"2026-10-10T10:00:02Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ok"}]}}'
} > "$fproj/codex/rollout-2026-10-10.jsonl"
foreign_case "context-guard.sh, Codex rollout transcript" "$GUARD" \
  "$(printf '{"session_id":"cx-1","hook_event_name":"UserPromptSubmit","transcript_path":"%s","cwd":"%s"}' "$fproj/codex/rollout-2026-10-10.jsonl" "$fproj")"
# Foreign input leaves no trace: no snapshot, no compacts.log line.
if [ ! -e "$fproj/.agents/runtime/handoff" ] && ! grep -q 'BLOCKED\|OK ' "$fhome/.claude/context-state/compacts.log" 2>/dev/null; then
  pass "foreign: no snapshot written and no BLOCKED/OK line in compacts.log"
else
  fail "foreign: left a trace" "handoff=$(ls "$fproj/.agents/runtime/handoff" 2>/dev/null) log=$(cat "$fhome/.claude/context-state/compacts.log" 2>/dev/null)"
fi
# The other side of the line: Claude input with no parser (jq and python3
# both missing) is still Claude's and still blocks — recognition is on the
# raw text, not on the parsed session_id.
shim=$(mktempdir)
for tool in jq python3; do printf '#!/bin/sh\nexit 127\n' > "$shim/$tool"; chmod +x "$shim/$tool"; done
printf '{"session_id":"np1","trigger":"auto","cwd":"%s","transcript_path":"/nonexistent.jsonl"}' "$fproj" \
  | HOME="$fhome" PATH="$shim:$PATH" "$BASH_BIN" "$PRECOMPACT" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then
  pass "Claude input, jq and python3 unavailable -> still rc 2 (block kept, not taken for foreign)"
else
  fail "Claude input without parsers no longer blocks" "rc=$rc"
fi
# autocheckpoint.sh called by our callers with an EMPTY --session stays loud.
"$BASH_BIN" "$AUTOCKPT" --session "" --cwd "$fproj" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 1 ] && pass "autocheckpoint.sh --session '' (our caller, empty id) -> rc 1 kept" \
  || fail "autocheckpoint.sh empty --session no longer rc 1" "rc=$rc"

finish
