#!/usr/bin/env bash
# claims-check.sh — проверка заявок на запись перед первой записью в репозиторий
# (протокол параллельных сессий, §8; формат и жизненный цикл заявки —
# references/context-rules.md этого же скилла).
#
# Отвечает РОВНО тремя состояниями, и это главное в его устройстве:
#   ЗАНЯТО    (rc=1) — есть живая чужая заявка, пересекающаяся с твоей областью;
#   СВОБОДНО  (rc=0) — проверка отработала и пересечений нет;
#   ВНИМАНИЕ  (rc=2) — проверить НЕ УДАЛОСЬ (битая строка, чужой формат даты,
#                      пропавшая секция, нечитаемый файл, неразобранный путь).
# «Не смог проверить» обязано отличаться от «проверил, чисто»: четыре круга
# гейта §6 (13-14.08) возвращали пакет ровно за то, что вторая ветка тихо
# выдавала себя за первую. Поэтому молчания в выводе нет вообще: пустой вывод
# сам по себе никогда не означает «свободно».
#
# Почему скрипт, а не копипаст-сниппет (решение человека 14.08, «Вариант А.»):
# сниппет сравнивал строки, а у одного и того же пути форм много — относительная
# и абсолютная, другой регистр, `~`, `..`, `./`, двойной и хвостовой слэш,
# симлинк по дороге, разная форма Unicode. Перечислить их строковым сравнением
# нельзя, поэтому обе стороны (заявка и запрашиваемая область) канонизируются
# по-настоящему: expanduser → абсолютизация от папки проектов → realpath
# (снимает симлинки, `..`, `.`, двойные и хвостовые слэши) → NFC → регистр.
#
# Использование:
#   claims-check.sh <область>
#     <область> — путь, который берёшь на запись: абсолютный, относительный
#     (от папки проектов), с `~`, с `..` — любая форма, скрипт приведёт сам.
#   Переменные окружения (обе необязательны):
#     TOOLS       — корень мастерской; по умолчанию вычисляется из места самого
#                   скрипта, поэтому незаданная переменная больше не может
#                   построить неверный путь и ответить успокаивающим «свободно».
#     CLAIMS_FILE — файл заявок целиком (перекрывает TOOLS).

set -uo pipefail

SELF="${BASH_SOURCE[0]:-$0}"
# Разрешаем симлинки: скрипт вызывают через поверхность
# ~/.claude/skills/pf-handoff/scripts/… , а корень мастерской надо вычислить
# от КАНОНА, куда эта цепочка ведёт.
if command -v python3 >/dev/null 2>&1; then
    SELF_REAL="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$SELF")"
else
    echo "ВНИМАНИЕ, проверка не отработала: нет python3, канонизировать пути нечем — читай файл заявок глазами" >&2
    exit 2
fi

exec python3 - "$SELF_REAL" "${1-}" <<'PYEOF'
# -*- coding: utf-8 -*-
import os
import re
import sys
import unicodedata
from datetime import datetime

SECTION = "## Живые заявки"
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$")

self_real = sys.argv[1]
raw_scope = sys.argv[2] if len(sys.argv) > 2 else ""

warn = []   # ВНИМАНИЕ — «не смог проверить»
busy = []   # ЗАНЯТО


def finish():
    for line in warn:
        print(line)
    for line in busy:
        print(line)
    if busy:
        sys.exit(1)
    if warn:
        sys.exit(2)
    sys.exit(0)


# ---- корень мастерской: из окружения или из места самого скрипта.
# scripts/ → pf-handoff/ → skills/ → skill-library/ → <корень мастерской>
tools = os.environ.get("TOOLS", "").strip()
if tools:
    tools = os.path.realpath(os.path.expanduser(tools))
    tools_src = "переменная TOOLS"
else:
    tools = os.path.realpath(os.path.join(os.path.dirname(self_real), *([os.pardir] * 4)))
    tools_src = "вычислен из места скрипта"

# Папка проектов — родитель мастерской: относительные заявки («_tools/AGENTS.md»,
# «optimize/.agents») отсчитываются от неё.
base = os.path.dirname(tools)

claims = os.environ.get("CLAIMS_FILE", "").strip()
if claims:
    claims = os.path.expanduser(claims)
else:
    claims = os.path.join(tools, ".agents", "runtime", "claims.md")


# ---- складывать ли регистр: спрашиваем не операционную систему, а саму
# файловую систему этой машины. На macOS том обычно регистронезависим
# (`_Tools/x` и `_tools/x` — один файл, складывать обязательно), на Linux/CI
# `Data/` и `data/` — разные каталоги, и складывание дало бы ложное ЗАНЯТО.
def fs_case_insensitive(path):
    path = path.rstrip(os.sep) or os.sep
    name = os.path.basename(path)
    alt = name.swapcase()
    if not name or alt == name:
        return sys.platform == "darwin"
    altpath = os.path.join(os.path.dirname(path), alt)
    try:
        return os.path.exists(altpath) and os.path.samefile(altpath, path)
    except OSError:
        return False


FOLD = fs_case_insensitive(tools if os.path.exists(tools) else base)


def canon(raw):
    """Любая форма пути → одна каноническая строка для сравнения."""
    s = unicodedata.normalize("NFC", raw.strip())
    s = os.path.expanduser(s)
    if not os.path.isabs(s):
        s = os.path.join(base, s)
    # realpath снимает симлинки, `..`, `.`, двойные и хвостовые слэши и
    # работает с ещё НЕ созданными путями: заявку подают до создания файлов.
    s = os.path.realpath(s)
    # macOS отдаёт кириллицу в путях то в NFC, то в NFD — один и тот же файл
    # двумя разными строками. Приводим к одной форме.
    s = unicodedata.normalize("NFC", s)
    return s.lower() if FOLD else s


def overlaps(a, b):
    """Пересечение по ГРАНИЦЕ пути: `_tools/security` не занимает
    `_tools/security-notes.md`, но занимает `_tools/security/gitleaks.py`."""
    return a == b or a.startswith(b + os.sep) or b.startswith(a + os.sep)


if not raw_scope.strip():
    warn.append("ВНИМАНИЕ, не задана область, которую берёшь на запись: "
                "claims-check.sh <путь>")
    finish()

try:
    scope_c = canon(raw_scope)
except (OSError, ValueError) as exc:
    warn.append("ВНИМАНИЕ, не удалось разобрать твою область «%s» (%s) — "
                "читай файл заявок глазами" % (raw_scope, exc))
    finish()

# ---- файла заявок нет. Спокойный ответ допустим ТОЛЬКО когда каталог
# .agents/runtime на месте и по пути не битый симлинк: иначе опечатка в TOOLS,
# указывающая на любой существующий каталог, вернула бы тихое «свободно».
if not os.path.isfile(claims):
    runtime_dir = os.path.dirname(claims)
    if os.path.isdir(runtime_dir) and not os.path.islink(claims):
        print("держаний нет: файла заявок ещё не заводили (%s)" % claims)
        sys.exit(0)
    warn.append("ВНИМАНИЕ, файла заявок нет по пути %s — проверь TOOLS (%s: %s) "
                "и не битый ли там симлинк" % (claims, tools_src, tools))
    finish()

try:
    with open(claims, encoding="utf-8", errors="replace") as fh:
        lines = fh.read().split("\n")
except OSError as exc:
    warn.append("ВНИМАНИЕ, проверка не отработала (%s) — читай файл глазами" % exc)
    finish()

now = datetime.now().strftime("%Y-%m-%d %H:%M")
live = False
seen = False

for line in lines:
    if line.startswith(SECTION):
        live, seen = True, True
        continue
    if line.startswith("## "):
        # Секция живых заявок заканчивается следующим заголовком: всё, что
        # ниже (например «## Архив»), — история, а не держания.
        live = False
        continue
    if not live or not line.strip():
        continue

    fields = line.split(" · ")
    if len(fields) < 5:
        warn.append("ВНИМАНИЕ, строка не разобрана (проверь глазами): " + line)
        continue

    scope, expires = fields[0], re.sub(r"^истекает ", "", fields[4])

    if " + " in scope:
        warn.append("ВНИМАНИЕ, составная область, одна строка = один путь: " + line)
        continue
    if not DATE_RE.match(expires):
        warn.append("ВНИМАНИЕ, срок не разобран, нужно YYYY-MM-DD HH:MM: " + line)
        continue
    if expires <= now:
        # Протухшая заявка свободна и молчит: брошенная строка не имеет права
        # блокировать работу навсегда.
        continue

    try:
        claim_c = canon(scope)
    except (OSError, ValueError) as exc:
        warn.append("ВНИМАНИЕ, область заявки не разобрана (%s): %s" % (exc, line))
        continue

    if overlaps(scope_c, claim_c):
        busy.append("ЗАНЯТО: " + line)

if not seen:
    warn.append("ВНИМАНИЕ, секция «%s» не найдена — проверь файл глазами" % SECTION)

if not busy and not warn:
    print("СВОБОДНО: живых заявок, пересекающихся с «%s», нет" % raw_scope)

finish()
PYEOF
