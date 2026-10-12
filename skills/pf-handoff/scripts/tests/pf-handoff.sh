#!/usr/bin/env bash
# Tests for pf-handoff.sh (T-168). One command: bash scripts/tests/pf-handoff.sh
# The script under test: $PF_HANDOFF_SH (a mutated copy for negative controls —
# keep it in a scripts/ directory beside a references/ with handoff-template.md,
# the script finds the template relative to itself), default — ../pf-handoff.sh.
# Temp projects only.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="${PF_HANDOFF_SH:-$TESTS_DIR/../pf-handoff.sh}"
[ -f "$S" ] || { echo "cannot find $S"; exit 90; }
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS  $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL  $1"; [ -n "${2:-}" ] && echo "      $2"; }
TMP=$(mktemp -d) && [ -d "$TMP" ] || { echo "mktemp -d failed"; exit 90; }
trap 'rm -rf "$TMP"' EXIT
proj() { local d="$TMP/$1"; mkdir -p "$d/.agents/runtime/handoff"; echo "$d"; }
hd() { echo "$1/.agents/runtime/handoff"; }

# --path: the newest ACTIVE one wins over a fresher closed one and a fresher
# file that has «status: active» only in its body (frontmatter anchor).
p=$(proj a)
printf -- '---\nstatus: active\n---\n# old active\n' > "$(hd "$p")/2026-10-01-old.md"
touch -t 202610010000 "$(hd "$p")/2026-10-01-old.md"
printf -- '---\nstatus: active\n---\n' > "$(hd "$p")/2026-10-05-mid.md"
touch -t 202610050000 "$(hd "$p")/2026-10-05-mid.md"
printf -- '---\nstatus: closed\n---\nstatus: active\n' > "$(hd "$p")/2026-10-09-closed.md"
printf -- '---\nstatus: inactive-active\n---\n' > "$(hd "$p")/2026-10-09-prefix.md"
printf -- '---\nstatus: closed\nprev_status: active\n---\n' > "$(hd "$p")/2026-10-09-prev.md"
printf -- '---\nstatus: actively-closed\n---\n' > "$(hd "$p")/2026-10-09-suffix.md"
printf -- 'status: active\n# no frontmatter\n' > "$(hd "$p")/2026-10-09-nofm.md"
out=$(cd "$p" && bash "$S" --path 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(basename "$out")" = 2026-10-05-mid.md ] \
  && pass "--path: newest frontmatter-active file; closed / body-only / no-frontmatter / prev_status / prefix / suffix ignored" \
  || fail "--path picked the wrong file" "rc=$rc out=$out"

# --path ignores $CLAUDE_PROJECT_DIR (answers for the directory it runs in).
q=$(proj other); printf -- '---\nstatus: active\n---\n' > "$(hd "$q")/2026-10-09-q.md"
out=$(cd "$p" && CLAUDE_PROJECT_DIR="$q" bash "$S" --path 2>&1)
[ "$(basename "$out")" = 2026-10-05-mid.md ] && pass "--path ignores CLAUDE_PROJECT_DIR" || fail "--path followed CLAUDE_PROJECT_DIR" "out=$out"

# --cwd overrides the current directory.
out=$(cd "$TMP" && bash "$S" --path --cwd "$q" 2>&1)
[ "$(basename "$out")" = 2026-10-09-q.md ] && pass "--cwd DIR" || fail "--cwd ignored" "out=$out"

# --path with no active HANDOFF: creates <date>-<slug>.md from the template.
e=$(proj empty); printf -- '---\nstatus: closed\n---\n' > "$(hd "$e")/2026-10-01-c.md"
out=$(cd "$e" && bash "$S" --path --slug T-999 2>&1); rc=$?
want="$(hd "$e")/$(date +%Y-%m-%d)-T-999.md"
if [ "$rc" = 0 ] && [ "$out" = "$want" ] && [ -f "$want" ] && head -3 "$want" | grep -q '^status: active$' \
   && grep -q '^## Не делать' "$want" && grep -q "^updated: $(date +%Y-%m-%d) " "$want"; then
  pass "--path without active HANDOFF: created from the template (status: active, updated now)"
else
  fail "--path did not create from the template" "rc=$rc out=$out"
fi
# N3: the create call itself puts .gitignore into the EXISTING directory
# (checked before the second call, which would add it on its own).
[ -f "$(hd "$e")/.gitignore" ] && pass "N3: --path creating a HANDOFF in an existing directory adds .gitignore" \
  || fail "N3: --path created a HANDOFF in an existing directory without .gitignore"
# … and the second call finds that same file instead of creating another one.
out2=$(cd "$e" && bash "$S" --path --slug other 2>&1)
[ "$out2" = "$want" ] && pass "--path second call returns the created file" || fail "--path created twice" "out2=$out2"
# No handoff directory at all: created.
n="$TMP/nodir"; mkdir -p "$n"
out=$(cd "$n" && bash "$S" --path 2>&1); rc=$?
[ "$rc" = 0 ] && [ -f "$out" ] && [ "$(basename "$out")" = "$(date +%Y-%m-%d)-handoff.md" ] \
  && pass "--path in a project without .agents/runtime/handoff: directory and file created (default slug)" \
  || fail "--path without the directory" "rc=$rc out=$out"
# QA 2.0.0 Y4: the freshly created directory ignores itself in git; N3: so does an existing one.
gi="$(hd "$n")/.gitignore"
[ "$(cat "$gi" 2>/dev/null)" = "$(printf '*\n!.gitignore')" ] \
  && pass "--path created the directory with a self-ignoring .gitignore (* / !.gitignore)" \
  || fail "--path: no .gitignore in the created directory" "$(cat "$gi" 2>&1)"
[ "$(cat "$(hd "$e")/.gitignore" 2>/dev/null)" = "$(printf '*\n!.gitignore')" ] \
  && pass "N3: --path puts the self-ignoring .gitignore into an existing HANDOFF directory too" \
  || fail "N3: --path left an existing HANDOFF directory without .gitignore" "$(ls -a "$(hd "$e")" 2>&1)"
# N3: an existing .gitignore is kept; --touch on an active HANDOFF adds a missing one;
# a symlink in place of .gitignore is not written through.
k=$(proj keep); printf 'mine\n' > "$(hd "$k")/.gitignore"
(cd "$k" && bash "$S" --path >/dev/null 2>&1)
[ "$(cat "$(hd "$k")/.gitignore")" = "mine" ] && pass "N3: --path keeps an existing .gitignore as is" || fail "N3: --path overwrote an existing .gitignore"
t=$(proj touchgi); printf -- '---\nstatus: active\nupdated: x\n---\n' > "$(hd "$t")/2026-10-01-a.md"
(cd "$t" && bash "$S" --touch >/dev/null 2>&1)
[ -f "$(hd "$t")/.gitignore" ] && pass "N3: --touch adds a missing .gitignore to the HANDOFF directory" || fail "N3: --touch left the directory without .gitignore"
l=$(proj link); ln -s "$TMP/victim-gi" "$(hd "$l")/.gitignore"
(cd "$l" && bash "$S" --path >/dev/null 2>&1)
[ ! -e "$TMP/victim-gi" ] && pass "N3: a dangling symlink in place of .gitignore is not written through" || fail "N3: .gitignore written through a symlink"
# Bad slug refused.
(cd "$n" && bash "$S" --path --slug ../x >/dev/null 2>&1); rc=$?
[ "$rc" = 2 ] && pass "--slug with a path separator refused (rc 2)" || fail "bad slug accepted" "rc=$rc"

# --short: <= 15 lines, the four required fields, a fifth «Запущено».
out=$(bash "$S" --short); rc=$?
lines=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
cnt=$(printf '%s\n' "$out" | grep -cE '^(Цель|Шаг|Доказано|Не делать):')
if [ "$rc" = 0 ] && [ "$lines" -le 15 ] && [ "$cnt" = 4 ] && printf '%s\n' "$out" | grep -q '^Запущено:'; then
  pass "--short: $lines lines, Цель/Шаг/Доказано/Не делать + Запущено"
else
  fail "--short format" "rc=$rc lines=$lines cnt=$cnt"
fi

# --touch: updates `updated:` in the active file only, body untouched.
t=$(proj touch)
printf -- '---\nstatus: active\nupdated: 2000-01-01 00:00\n---\nupdated: body-stays\n' > "$(hd "$t")/2026-10-09-t.md"
out=$(cd "$t" && bash "$S" --touch 2>&1); rc=$?
f="$(hd "$t")/2026-10-09-t.md"
if [ "$rc" = 0 ] && sed -n 3p "$f" | grep -q "^updated: $(date +%Y-%m-%d) " && grep -q '^updated: body-stays$' "$f"; then
  pass "--touch: frontmatter updated: refreshed, body untouched"
else
  fail "--touch" "rc=$rc out=$out file=$(cat "$f")"
fi
# --touch keeps the file's permissions (600 stays 600) and leaves no temp file behind.
chmod 600 "$f"; (cd "$t" && bash "$S" --touch >/dev/null 2>&1); rc=$?
perm=$(stat -f %Lp "$f" 2>/dev/null || stat -c %a "$f" 2>/dev/null)
left=$(find "$(hd "$t")" -name '*.tmp' | wc -l | tr -d ' ')
[ "$rc" = 0 ] && [ "$perm" = 600 ] && [ "$left" = 0 ] && pass "--touch: mode 600 kept, no temp file left" \
  || fail "--touch permissions / temp" "rc=$rc perm=$perm left=$left"
# 644 too: mkstemp creates 600, so only a non-600 mode proves the copy of the original bits.
chmod 644 "$f"; (cd "$t" && bash "$S" --touch >/dev/null 2>&1); rc=$?
perm=$(stat -f %Lp "$f" 2>/dev/null || stat -c %a "$f" 2>/dev/null)
[ "$rc" = 0 ] && [ "$perm" = 644 ] && pass "--touch: mode 644 kept (not mkstemp's 600)" || fail "--touch mode 644 lost" "rc=$rc perm=$perm"
# --touch on a symlinked HANDOFF: refused (rc 1, message), target untouched, link kept.
l=$(proj link); printf -- '---\nstatus: active\nupdated: 2000-01-01 00:00\n---\n' > "$TMP/target.md"
ln -s "$TMP/target.md" "$(hd "$l")/2026-10-09-l.md"
msg=$(cd "$l" && bash "$S" --touch 2>&1); rc=$?
if [ "$rc" = 1 ] && printf '%s' "$msg" | grep -q 'symlink' && [ -L "$(hd "$l")/2026-10-09-l.md" ] \
   && grep -q '^updated: 2000-01-01 00:00$' "$TMP/target.md"; then
  pass "--touch on a symlink: refused rc 1 with a message, target and link untouched"
else
  fail "--touch wrote through a symlink" "rc=$rc msg=$msg"
fi
# --path never overwrites an existing non-active <date>-<slug>.md (create mode): rc 1, content kept.
o=$(proj noover); keep="$(hd "$o")/$(date +%Y-%m-%d)-handoff.md"
printf -- '---\nstatus: closed\n---\nKEEP-MARKER-T168\n' > "$keep"
msg=$(cd "$o" && bash "$S" --path 2>&1); rc=$?
if [ "$rc" = 1 ] && grep -q '^KEEP-MARKER-T168$' "$keep" && grep -q '^status: closed$' "$keep"; then
  pass "--path create mode: an existing closed <date>-<slug>.md is not overwritten (rc 1, marker kept)"
else
  fail "--path overwrote an existing file" "rc=$rc msg=$msg file=$(cat "$keep")"
fi
# --touch with no active HANDOFF: rc 1, loud.
(cd "$e" && rm -f "$want" && bash "$S" --touch >/dev/null 2>&1); rc=$?
[ "$rc" = 1 ] && pass "--touch without active HANDOFF: rc 1" || fail "--touch without active HANDOFF" "rc=$rc"

# Usage errors.
bash "$S" >/dev/null 2>&1; r1=$?; bash "$S" --bogus >/dev/null 2>&1; r2=$?; bash "$S" --path --short >/dev/null 2>&1; r3=$?
[ "$r1" = 2 ] && [ "$r2" = 2 ] && [ "$r3" = 2 ] && pass "no mode / unknown arg / two modes: rc 2" || fail "usage rc" "$r1 $r2 $r3"

echo; echo "TOTAL: $PASS/$((PASS + FAIL))"
[ "$FAIL" = 0 ]
