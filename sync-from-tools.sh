#!/bin/bash
# Синхронизация дистрибутива из канона разработки перед релизом.
# Канон живёт в _tools: skill-library/skills/{pf-handoff,pf-resume} и context-hooks/*.sh.
# Запуск: bash sync-from-tools.sh [путь-к-_tools]
# Дальше руками: git diff → запись в CHANGELOG.md → commit → tag vX.Y.Z → push --tags.
set -euo pipefail

TOOLS="${1:-$HOME/Проекты ai/_tools}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

[ -d "$TOOLS/skill-library/skills/pf-handoff" ] || { echo "ОШИБКА: не найден канон в $TOOLS" >&2; exit 2; }

rsync -a --delete "$TOOLS/skill-library/skills/pf-handoff/" "$HERE/skills/pf-handoff/"
rsync -a --delete "$TOOLS/skill-library/skills/pf-resume/"  "$HERE/skills/pf-resume/"
rsync -a --delete --include='*.sh' --exclude='*' "$TOOLS/context-hooks/" "$HERE/hooks/"

echo "Синхронизировано из: $TOOLS"
echo "Дальше: git diff → CHANGELOG.md → commit → tag vX.Y.Z → git push --tags"
