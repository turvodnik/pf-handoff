#!/bin/bash
# pf-handoff: полная установка одной командой — скиллы (копиями) + хуки + проверка.
# One-command install: skills (as copies) + hooks + health check.
# Копии не зависят от расположения клона: после установки его можно перемещать
# или удалять. Обновление: git pull && bash install.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

echo "== pf-handoff: установка =="

# 1) Скиллы — копиями, не симлинками.
install_skill_into() {
  local surface="$1" sk="$2"
  local dst="$surface/$sk"
  if [ -L "$dst" ]; then
    echo "ПРОПУСК: $dst — симлинк (управляется другим механизмом; снимите его вручную, если хотите копию)"
    return 0
  fi
  if [ -d "$dst" ]; then
    # Сносим только СВОЮ прежнюю копию (SKILL.md с нашим именем) — чужую
    # одноимённую папку не трогаем: молчаливый rm -rf чужих данных недопустим.
    if grep -q "^name: $sk\$" "$dst/SKILL.md" 2>/dev/null; then
      rm -rf "$dst"
      echo "обновляю: $dst"
    else
      echo "ПРОПУСК: $dst — существующая папка не похожа на наш скилл (нет «name: $sk» в SKILL.md); разберитесь вручную"
      return 0
    fi
  fi
  mkdir -p "$surface"
  cp -R "$HERE/skills/$sk" "$dst"
  echo "OK: $dst"
}

for sk in pf-handoff pf-resume; do
  install_skill_into "$HOME/.claude/skills" "$sk"
  # Codex/Gemini — только если эти CLI есть на машине: мусорных папок не создаём.
  if [ -d "$HOME/.codex" ]; then install_skill_into "$HOME/.codex/skills" "$sk"; fi
  if [ -d "$HOME/.gemini" ]; then install_skill_into "$HOME/.gemini/skills" "$sk"; fi
done

# 2) Хуки (бэкап settings.json — автоматически; отсутствующий settings.json создаётся).
bash "$HERE/hooks/install.sh"

# 3) Проверка здоровья.
bash "$HERE/hooks/doctor.sh"

echo
echo "Готово. Последний шаг руками: вставьте docs/rules-section.md (EN) или docs/rules-section.ru.md (RU)"
echo "в конец вашего ~/.claude/CLAUDE.md — это правила, по которым агент ведёт HANDOFF."
