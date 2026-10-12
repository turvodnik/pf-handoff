#!/bin/bash
# pf-handoff: one-command install — skills (as copies) + hooks + health check.
# Copies do not depend on the clone location: after installing you may move
# or delete the clone. Update: git pull && bash install.sh [--force]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

echo "== pf-handoff: install =="

# python3 is required by the hook installer (hooks/install.sh). Checked here,
# before the skills are copied: without it the install used to stop half-way —
# skills new, hooks old (QA 2.0.0, Y1). jq alone is enough for the hooks
# themselves, not for installing them.
if ! command -v python3 >/dev/null 2>&1; then
  echo "pf-handoff: python3 is required to install (not found on PATH) — nothing was changed." >&2
  echo "Install python3 (macOS: xcode-select --install; Debian/Ubuntu: sudo apt install python3) and re-run bash install.sh." >&2
  exit 1
fi

# 1) Skills — as copies, not symlinks.
install_skill_into() {
  local surface="$1" sk="$2"
  local dst="$surface/$sk"
  if [ -L "$dst" ]; then
    echo "SKIP: $dst is a symlink (managed by another mechanism; remove it manually if you want a copy)"
    return 0
  fi
  if [ -d "$dst" ]; then
    # Remove only OUR previous copy (SKILL.md carries our name) — a foreign
    # same-named directory is left alone: silently rm -rf'ing other people's
    # data is unacceptable.
    if grep -q "^name: $sk\$" "$dst/SKILL.md" 2>/dev/null; then
      rm -rf "$dst"
      echo "updating: $dst"
    else
      echo "SKIP: $dst — existing directory does not look like our skill (no \"name: $sk\" in SKILL.md); resolve manually"
      return 0
    fi
  fi
  mkdir -p "$surface"
  cp -R "$HERE/skills/$sk" "$dst"
  echo "OK: $dst"
}

for sk in pf-handoff pf-resume; do
  install_skill_into "$HOME/.claude/skills" "$sk"
  # Codex/Gemini — only if those CLIs exist on this machine: no junk directories.
  if [ -d "$HOME/.codex" ]; then install_skill_into "$HOME/.codex/skills" "$sk"; fi
  if [ -d "$HOME/.gemini" ]; then install_skill_into "$HOME/.gemini/skills" "$sk"; fi
done

# 2) Hooks (settings.json is backed up automatically; a missing settings.json is created).
# A registration pointing at an existing file outside this clone is kept
# (KEPT: line); `bash install.sh --force` points it at this clone.
bash "$HERE/hooks/install.sh" "$@"

# 3) Health check.
bash "$HERE/hooks/doctor.sh"

echo
echo "Done. One manual step left: paste docs/rules-section.md (EN) or docs/rules-section.ru.md (RU)"
echo "at the end of your ~/.claude/CLAUDE.md — these are the rules the agent keeps the HANDOFF by."
