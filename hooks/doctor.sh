#!/bin/bash
# Проверка здоровья установки context-hooks. Печатает OK/FAIL по каждой
# проверке, exit 1 при любой FAIL. Оператор-инструмент (не хук) — как
# install.sh, ошибки это exit 1, а не молчаливый exit 0.
set -u

SETTINGS_PATH="${CLAUDE_SETTINGS_PATH:-$HOME/.claude/settings.json}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
STATE_DIR="$HOME/.claude/context-state"

FAIL=0

ok()   { printf 'OK   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; FAIL=1; }

# 1) шесть скриптов существуют и исполняемы
for name in statusline.sh context-guard.sh sessionstart.sh precompact.sh install.sh doctor.sh; do
  if [ -x "$SCRIPT_DIR/$name" ]; then
    ok "скрипт $name существует и исполняем"
  else
    fail "скрипт $name отсутствует или не исполняем ($SCRIPT_DIR/$name)"
  fi
done

# 2) settings.json валиден
if python3 -m json.tool "$SETTINGS_PATH" > /dev/null 2>&1; then
  ok "settings.json валиден ($SETTINGS_PATH)"
else
  fail "settings.json невалиден или не найден ($SETTINGS_PATH)"
fi

# 3) содержит все 5 наших записей (statusLine + 4 хука).
# Паттерны — по имени файла, без имени каталога: в каноне это context-hooks/,
# в публичном дистрибутиве — hooks/.
if grep -q "/statusline.sh" "$SETTINGS_PATH" 2>/dev/null; then
  ok "statusLine указывает на наш statusline.sh"
else
  fail "statusLine не найден/не указывает на наш statusline.sh"
fi

if [ "$(grep -c "/context-guard.sh" "$SETTINGS_PATH" 2>/dev/null || echo 0)" -ge 2 ] 2>/dev/null; then
  ok "context-guard.sh зарегистрирован в UserPromptSubmit и PostToolUse"
else
  fail "context-guard.sh не зарегистрирован (нужно 2 вхождения: UserPromptSubmit + PostToolUse)"
fi

if grep -q "/sessionstart.sh" "$SETTINGS_PATH" 2>/dev/null; then
  ok "sessionstart.sh зарегистрирован в SessionStart"
else
  fail "sessionstart.sh не зарегистрирован в SessionStart"
fi

if grep -q "/precompact.sh" "$SETTINGS_PATH" 2>/dev/null; then
  ok "precompact.sh зарегистрирован в PreCompact"
else
  fail "precompact.sh не зарегистрирован в PreCompact"
fi

# 4) совместимость с Orca — проверяется ТОЛЬКО если Orca установлена на этой
# машине (~/.orca/agent-hooks существует). На машинах без Orca это не ошибка:
# statusline-обёртка просто пропускает отсутствующий скрипт.
if [ -d "$HOME/.orca/agent-hooks" ]; then
  orca_hook_count=$(grep -c 'claude-hook.sh' "$SETTINGS_PATH" 2>/dev/null || echo 0)
  if [ "$orca_hook_count" -ge 1 ] 2>/dev/null; then
    ok "орковские хуки на месте (claude-hook.sh встречается $orca_hook_count раз)"
  else
    fail "Orca установлена, но её хуков в settings.json нет (claude-hook.sh: 0) — проверь, не затёрты ли"
  fi
  if [ -f "$SCRIPT_DIR/statusline.sh" ] && grep -q "claude-statusline.sh" "$SCRIPT_DIR/statusline.sh" 2>/dev/null; then
    ok "наш statusline.sh по-прежнему вызывает орковский claude-statusline.sh"
  else
    fail "наш statusline.sh не ссылается на орковский claude-statusline.sh"
  fi
else
  ok "Orca не установлена — проверки совместимости пропущены (это норма)"
fi

# 5) ~/.claude/context-state/ создаваем/записываем
if mkdir -p "$STATE_DIR" 2>/dev/null; then
  probe="$STATE_DIR/.doctor-probe.$$"
  if printf 'probe' > "$probe" 2>/dev/null; then
    rm -f "$probe" 2>/dev/null
    ok "$STATE_DIR создаваем и записываем"
  else
    fail "$STATE_DIR существует, но недоступен для записи"
  fi
else
  fail "$STATE_DIR не удалось создать"
fi

exit "$FAIL"
