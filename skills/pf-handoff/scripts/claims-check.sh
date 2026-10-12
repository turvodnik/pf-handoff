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
# Что именно приводится к канону: разные ЗАПИСИ одного и того же пути. Разный
# смысл одной записи привести нельзя, и скрипт этого не обещает: относительный
# путь файл заявок отсчитывает от папки проектов, а человек в оболочке — от
# текущего каталога. Если эти два прочтения расходятся, скрипт говорит об этом
# вслух (`ВНИМАНИЕ, относительный путь неоднозначен`) и проверяет ОБА, а не
# выбирает одно молча.
#
# Использование:
#   claims-check.sh [--sid <8hex>] <область>
#   claims-check.sh --sweep [--yes]
#     <область> — путь, который берёшь на запись. Любая ЗАПИСЬ пути годится
#     (абсолютный, с `~`, с `..`, `./`, лишними слэшами, симлинками, в любом
#     регистре и форме Unicode). Относительный отсчитывается от папки проектов
#     — как в файле заявок; неоднозначный даёт `ВНИМАНИЕ`. Однозначный ответ
#     даёт абсолютный путь.
#   Переменные окружения (обе необязательны):
#     TOOLS       — корень мастерской; по умолчанию вычисляется из места самого
#                   скрипта, поэтому незаданная переменная больше не может
#                   построить неверный путь и ответить успокаивающим «свободно».
#                   Заданная ВРУЧНУЮ и неверная — тоже: при перекрытии
#                   отсутствие файла заявок даёт `ВНИМАНИЕ`, а не «держаний нет».
#                   Вычисленный корень ПРОВЕРЯЕТСЯ (каталог skill-library/ на
#                   месте): у скилла, установленного копией в ~/.claude/skills,
#                   место скрипта до мастерской не ведёт, там нужен TOOLS.
#     CLAIMS_FILE — файл заявок целиком (перекрывает TOOLS).
#     CLAIMS_SID  — свой идентификатор сессии (8 hex), то же, что `--sid`;
#                   флаг важнее переменной.
#
#   Сессия в заявке (T-122, I-066): в поле «кто» можно дописать токен
#   `sid:<8 hex>` — `claude (pf-executor) sid:1a2b3c4d`. Поле необязательно,
#   старые строки без него проходят как раньше. Две сессии одного `claude`
#   строка без sid не различает (T-052 дубль-диспатч; проекты клиентов 09.09
#   и 17.09 — исполнитель принял свою же заявку за чужую).
#   С заданным своим sid (`--sid`/CLAIMS_SID) пересечение с заявкой ТОГО ЖЕ
#   sid — `СВОБОДНО (своя): <строка>` (rc 0); другой sid или строка без sid —
#   `ЗАНЯТО` (rc 1). Без своего sid поведение прежнее: всякое живое
#   пересечение — ЗАНЯТО. Токен не по форме (`sid:XYZ`, 7 знаков, верхний
#   регистр) — ВНИМАНИЕ (rc 2): опечатка в sid не имеет права выдать чужую
#   заявку за свою или свою за чужую молча. Токен живёт ВНУТРИ поля «кто»,
#   а не отдельным сегментом: число полей остаётся 5, позиция «истекает»
#   (fields[4]) не сдвигается, и соседи на старой версии скрипта читают
#   такую строку без ошибок (проверено на HEAD до правки).
#
#   Границы ЖИВОЙ проверки (T-156, Н1 аудита 02.10) — весь файл после шапки,
#   а не только секция «## Живые заявки»: Claude дописывает заявки в конец
#   файла под чужие заголовки, и проверка отвечала СВОБОДНО над живой заявкой.
#   В живой секции каждая непустая строка обязана быть заявкой (как раньше);
#   под чужим заголовком заявка — строка с пятым полем `истекает …`, проза там
#   молчит. Снятая (`СНЯТО`/`СНЯТА`) и истёкшая строки не живые. Составная
#   область разворачивается в перечень путей (фикс-раунд 1): части через « + »,
#   хвост-пометка «(…)», `{a,b}` как в shell, список «a, b», глоб → свой
#   каталог; иначе скобки читались бы как буквальное имя и не защищали ни один
#   файл. ВНИМАНИЕ — только нераспознаваемая область (незакрытая скобка). sid
#   сверяется у пересёкшейся строки: битый токен у чужой непересекающейся
#   строки ничего не решает. Срок
#   с хвостом (пояс `WEST`, `истекает:`, дата без времени) молчит, только если
#   прошёл больше 26 ч назад (дальше пояса срок не сдвигают), иначе ВНИМАНИЕ.
#
#   Свип протухших (T-122, I-067): `--sweep` печатает `ПРОТУХЛА <срок>: <строка>`
#   и итог `протухших: N`, файл НЕ трогает; `--sweep --yes` переносит найденное
#   в `claims-archive.md` рядом с файлом заявок (секция `## Архив протухших`,
#   к строке дописывается ` · протухла <YYYY-MM-DD HH:MM>`) и удаляет из
#   `claims.md`. Уровень L2: `--yes` подтверждает человек.
#   Границы сканирования — ВЕСЬ файл, а не только секция «Живые заявки»:
#   в живом файле строки формата заявки лежат и под чужими `## `-заголовками
#   (G-A4, T-139 — по парсеру живой секции это «история», и они висели там
#   три ретро подряд). Строкой формата заявки считается любая строка (после
#   необязательного маркера списка `- `), у которой ≥5 полей через ` · ` и
#   пятое поле — `истекает YYYY-MM-DD HH:MM`; строка с полем `СНЯТО`/`СНЯТА`
#   дальше по строке уже снята руками — её свип не трогает (перенести её как
#   «протухла» было бы ложью; в отчёте они считаются отдельной строкой
#   «снятых руками и истёкших: K»). Шапка файла (до первого `## `) не
#   сканируется: там проза с примерами формата. УСПЕШНЫЙ свип-отчёт в
#   событийный лог НЕ пишет: свип — не проверка заявки, а `hygiene-sweep.sh`
#   считает каждую строку лога проверкой; `--yes` (мутация файла) пишет одну
#   строку `СВИП`, ошибка аргументов/переноса — `ВНИМАНИЕ` через finish(),
#   как у любой проверки (громко, не молча).

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

exec python3 - "$SELF_REAL" "$@" <<'PYEOF'
# -*- coding: utf-8 -*-
import getpass
import os
import re
import socket
import sys
import unicodedata
from datetime import datetime, timedelta

SECTION = "## Живые заявки"
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$")
# sid — ровно 8 hex в нижнем регистре; токен ищется в поле «кто» (fields[2]).
SID_RE = re.compile(r"^[0-9a-f]{8}$")
SID_TOKEN_RE = re.compile(r"(?:^|\s)sid:(\S*)")
ARCHIVE_NAME = "claims-archive.md"
ARCHIVE_SECTION = "## Архив протухших"

self_real = sys.argv[1]

warn = []   # ВНИМАНИЕ — «не смог проверить»
busy = []   # ЗАНЯТО
own = []    # СВОБОДНО (своя) — пересечение с заявкой моей же сессии

# ---- разбор аргументов руками: argparse печатает англоязычный usage и
# выходит с rc 2 без слова ВНИМАНИЕ — а контракт «три ответа, молчания нет»
# требует слова. Флаги: --sid <8hex>, --sweep, --yes; одна позиционная область.
raw_scope = ""
sweep = False
yes = False
sid_flag = None
args = sys.argv[2:]
i = 0
while i < len(args):
    a = args[i]
    if a == "--sid":
        if i + 1 >= len(args):
            warn.append("ВНИМАНИЕ, у --sid нет значения: --sid <8 hex>")
            i += 1
            continue
        sid_flag = args[i + 1]
        i += 2
        continue
    if a.startswith("--sid="):
        sid_flag = a[len("--sid="):]
    elif a == "--sweep":
        sweep = True
    elif a == "--yes":
        yes = True
    elif a.startswith("--") and len(a) > 2:
        warn.append("ВНИМАНИЕ, неизвестный аргумент «%s»: claims-check.sh [--sid <8hex>] "
                    "<путь> | --sweep [--yes]" % a)
    elif raw_scope:
        warn.append("ВНИМАНИЕ, область задана дважды («%s» и «%s»), одна проверка = "
                    "одна область" % (raw_scope, a))
    else:
        raw_scope = a
    i += 1

if yes and not sweep:
    warn.append("ВНИМАНИЕ, --yes имеет смысл только вместе с --sweep")
if sweep and raw_scope:
    warn.append("ВНИМАНИЕ, --sweep не принимает область («%s»): свип смотрит весь "
                "файл, проверка области — отдельный вызов" % raw_scope)

if sid_flag is not None:
    my_sid, my_sid_src = sid_flag, "--sid"
elif "CLAIMS_SID" in os.environ:
    my_sid, my_sid_src = os.environ["CLAIMS_SID"], "CLAIMS_SID"
else:
    my_sid, my_sid_src = "", ""
if my_sid_src and not SID_RE.match(my_sid):
    # Пустое значение — тоже ошибка: «--sid ""» задан, значит сессия ХОТЕЛА
    # назваться, и молча работать «без sid» (своя заявка → ЗАНЯТО) — молчание.
    warn.append("ВНИМАНИЕ, свой sid «%s» (%s) не по форме (нужно 8 hex в нижнем "
                "регистре, например 1a2b3c4d) — без верного sid своя заявка от "
                "чужой не отличается" % (my_sid, my_sid_src))
    my_sid = ""


def line_sid(who_field):
    """Токен sid из поля «кто»: (sid, ошибка). Нет токена → (None, None);
    токен есть, но не по форме → (None, текст ошибки)."""
    m = SID_TOKEN_RE.search(who_field)
    if not m:
        return None, None
    # «sid:1a2b3c4d)» — токен в скобках пометки: хвостовую пунктуацию срезаем.
    value = m.group(1).rstrip(")],;.")
    if not SID_RE.match(value):
        return None, "sid «%s» не по форме (8 hex в нижнем регистре)" % value
    return value, None

# ---- событийный лог (T-040, фикс-круг 2 — решение человека 15.08): каждая
# проверка дописывает одну строку в журнал, ЧТОБЫ ЗАМЕР §8 стал возможен
# вообще — история держаний нигде больше не сохраняется (T-038: git-история
# по `claims.md` структурно пуста, замер без отдельного лога невозможен).
#
# Фикс-круг 1 держал лог версируемым и объяснял запись без заявки
# самопровозглашённым исключением из §8. Гейт вернул пакет: агент не выдаёт
# себе исключений из правил человека — это решение человека, а не
# инженерный компромисс, который можно принять за него. Урок записан в
# «Результате» пакета отдельной строкой, не как оправдание.
#
# РЕШЕНИЕ ЧЕЛОВЕКА (15.08): лог живёт ВНЕ git, рядом с `claims.md`, в том
# же самом `.agents/runtime/` (уже в .gitignore целиком). Парадокс исчезает
# не через исключение, а через факт: запись в неверсируемый файл — не
# «запись в репозиторий» в смысле §8 (правило защищает git-дерево от
# конфликтующих правок), заявка тут не нужна не потому, что мы её отменили,
# а потому, что предмет заявки — вне области действия правила. Свип
# (`optimize/scripts/hygiene-sweep.sh`, проверка 6) читает файл напрямую,
# не через git log — то, ради чего лог и заводили, замер не завязан на
# версирование.
now_str = datetime.now().strftime("%Y-%m-%d %H:%M")
scope_forms_for_log = None   # заполняется, когда область успешно канонизирована


def _sanitize_field(value):
    """Поле не имеет права перенести строку — иначе одно событие станет
    двумя (или больше) строками лога и счёт в свипе будет враньём. Перевод
    строки и CR — единственное, что здесь опасно (разделитель ` · ` и без
    того не встречается в путях/именах в естественных условиях)."""
    return value.replace("\r\n", " ").replace("\n", " ").replace("\r", " ")


def log_path_for(claims_path):
    log_override = os.environ.get("CLAIMS_LOG", "").strip()
    if log_override:
        # Тесты/пробники обязаны переопределять именно эту переменную, а не
        # полагаться на TOOLS/вычисление корня — так утечка события в
        # боевой лог из песочницы структурно исключена, а не «обычно не
        # происходит».
        return os.path.expanduser(log_override)
    # Рядом с claims.md — та же директория, версируемая или нет неважно:
    # решение человека делает лог НЕВЕРСИРУЕМЫМ ПО МЕСТУ (`.agents/runtime/`
    # целиком в .gitignore), а не по отдельному правилу для одного файла.
    return os.path.join(os.path.dirname(claims_path), "claims-events.log")


def log_event(claims_path, verdict):
    """Дозаписать одно событие. Ничего не решает за основную проверку:
    падение дозаписи не должно менять ни вердикт, ни код выхода (задача
    T-040, п.4) — только сказать о проблеме вслух, не молча и не падением.
    Каталог под лог никогда не создаётся здесь: `.agents/runtime/` уже
    существует у каждого проекта по §9, а слепой mkdir на ошибочном/левом
    TOOLS плодил бы каталоги в непроверенных местах."""
    path_field = _sanitize_field(scope_forms_for_log if scope_forms_for_log
                                  else (raw_scope.strip() or "(путь не задан)"))
    who = _sanitize_field(os.environ.get("CLAIMS_ACTOR", "").strip())
    if not who:
        # Голый user@host не отличает параллельные сессии на одной машине —
        # добавляем PID процесса (у каждого вызова claims-check.sh свой).
        # Это НЕ подменяет полноценную атрибуцию: несколько вызовов ОДНОЙ
        # сессии всё ещё не связаны общим идентификатором без CLAIMS_ACTOR —
        # честно называем предел, не изображаем точность.
        try:
            who = "%s@%s:%s" % (getpass.getuser(), socket.gethostname(), os.getpid())
        except Exception:
            who = "неизвестно:%s" % os.getpid()
        who = _sanitize_field(who)
    line = "%s · %s · %s · %s\n" % (now_str, path_field, verdict, who)
    log_path = log_path_for(claims_path)
    log_dir = os.path.dirname(log_path)
    try:
        if not os.path.isdir(log_dir):
            sys.stderr.write(
                "ПРЕДУПРЕЖДЕНИЕ, событие в лог заявок не записано: каталог %s "
                "не существует — не создаю его вслепую (вердикт проверки "
                "заявки это не меняет)\n" % log_dir
            )
            return
        with open(log_path, "a", encoding="utf-8") as fh:
            fh.write(line)
    except OSError as exc:
        sys.stderr.write(
            "ПРЕДУПРЕЖДЕНИЕ, не удалось дописать событие в лог заявок %s (%s) — "
            "вердикт проверки заявки это не меняет\n" % (log_path, exc)
        )


def finish():
    verdict = "ЗАНЯТО" if busy else ("ВНИМАНИЕ" if warn else "СВОБОДНО")
    log_event(claims, verdict)
    for line in warn:
        print(line)
    for line in own:
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
    tools_src = "переменная CLAIMS_FILE"
else:
    claims = os.path.join(tools, ".agents", "runtime", "claims.md")

# Путь к файлу заявок задан руками (TOOLS или CLAIMS_FILE) — значит его никто
# не проверял; спокойная ветка «файла ещё не заводили» на него не полагается.
overridden = tools_src != "вычислен из места скрипта"

# Вычисленный корень тоже надо ПРОВЕРИТЬ, а не принять на веру. Правило «четыре
# уровня вверх» верно только для канонного расположения
# (<мастерская>/skill-library/skills/pf-handoff/scripts/); в публичном
# дистрибутиве установщик кладёт скилл КОПИЕЙ в ~/.claude/skills/pf-handoff/,
# симлинк-цепочки нет, и те же четыре уровня дают корень = $HOME. Если при этом
# у человека есть ~/.agents/runtime (а у пользователя глобального канона он
# заводится сам), спокойная ветка ниже отвечала «держаний нет» поверх заведомо
# неверного корня — то самое «не смог проверить» под видом «проверил, чисто».
# Признак мастерской — каталог skill-library/ у самого корня.
workshop = os.path.isdir(os.path.join(tools, "skill-library"))


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


def canon_one(path):
    """Одна абсолютная запись пути → каноническая строка для сравнения."""
    # realpath снимает симлинки, `..`, `.`, двойные и хвостовые слэши и
    # работает с ещё НЕ созданными путями: заявку подают до создания файлов.
    s = os.path.realpath(path)
    # macOS отдаёт кириллицу в путях то в NFC, то в NFD — один и тот же файл
    # двумя разными строками. Приводим к одной форме.
    s = unicodedata.normalize("NFC", s)
    return s.lower() if FOLD else s


def canon(raw, from_cwd=False):
    """Запись пути → список канонических форм + предупреждение о неоднозначности.

    Форм больше одной ровно в одном случае: ОБЛАСТЬ задана относительным путём,
    и два законных прочтения расходятся. Файл заявок отсчитывает относительный
    путь от папки проектов, оболочка человека — от текущего каталога; молча
    выбрать одно из двух — это и есть тихое «свободно» поверх живой заявки.
    Строки САМОГО файла заявок читаются только от папки проектов (from_cwd
    False): у них форма задокументирована, и текущий каталог проверяющего к их
    смыслу отношения не имеет — иначе законная строка «_tools/AGENTS.md» кричала
    бы `ВНИМАНИЕ` при каждом прогоне из любого проекта.
    """
    s = unicodedata.normalize("NFC", raw.strip())
    s = os.path.expanduser(s)
    if os.path.isabs(s):
        return [canon_one(s)], None
    from_base = os.path.join(base, s)
    forms = [canon_one(from_base)]
    if not from_cwd:
        return forms, None
    try:
        cwd = os.getcwd()
    except OSError as exc:
        return forms, ("ВНИМАНИЕ, текущий каталог не определяется (%s), а путь «%s» "
                       "относительный — дай абсолютный" % (exc, raw.strip()))
    alt = os.path.join(cwd, s)
    alt_c = canon_one(alt)
    if alt_c == forms[0]:
        return forms, None
    forms.append(alt_c)
    return forms, ("ВНИМАНИЕ, относительный путь неоднозначен: «%s» — это «%s» "
                   "(от папки проектов, как в файле заявок) или «%s» (от текущего "
                   "каталога)? Проверил ОБА прочтения; чтобы ответ был один, "
                   "дай абсолютный путь" % (raw.strip(), from_base, alt))


def overlaps(a, b):
    """Пересечение по ГРАНИЦЕ пути: `_tools/security` не занимает
    `_tools/security-notes.md`, но занимает `_tools/security/gitleaks.py`."""
    return a == b or a.startswith(b + os.sep) or b.startswith(a + os.sep)


def any_overlap(scopes, claims_forms):
    """Пересеклось хотя бы одно прочтение области с одним прочтением заявки.
    Сознательно консервативно: у неоднозначной области ЗАНЯТО печатается и
    тогда, когда пересекается только прочтение «от текущего каталога»."""
    return any(overlaps(s, c) for s in scopes for c in claims_forms)


if warn:
    # Ошибка в самих аргументах (неизвестный флаг, битый свой sid, --yes без
    # --sweep, две области) — стоп до проверки: результат поверх неверно
    # понятого вызова был бы правдой случайно («ЗАНЯТО» по чужой строке) или
    # ложью («СВОБОДНО (своя)» по битому sid).
    finish()

if sweep:
    scope_forms = []
    scope_forms_for_log = "(свип протухших)"
elif not raw_scope.strip():
    warn.append("ВНИМАНИЕ, не задана область, которую берёшь на запись: "
                "claims-check.sh <путь>")
    finish()
else:
    try:
        scope_forms, ambiguous = canon(raw_scope, from_cwd=True)
    except (OSError, ValueError) as exc:
        warn.append("ВНИМАНИЕ, не удалось разобрать твою область «%s» (%s) — "
                    "читай файл заявок глазами" % (raw_scope, exc))
        finish()

    scope_forms_for_log = " | ".join(scope_forms)

    if ambiguous:
        warn.append(ambiguous)

# ---- файла заявок нет. Спокойный ответ допустим ТОЛЬКО когда каталог
# .agents/runtime на месте, по пути не битый симлинк И корень ВЫЧИСЛЕН, а не
# перекрыт руками: каталог `.agents/runtime` есть по §9 у каждого проекта,
# поэтому опечатка вроде `TOOLS=$(pwd)` иначе вернула бы спокойное «держаний
# нет» поверх живых заявок в настоящем файле.
if not os.path.isfile(claims):
    runtime_dir = os.path.dirname(claims)
    if os.path.isdir(runtime_dir) and not os.path.islink(claims) and not overridden and workshop and not sweep:
        if warn:
            finish()   # неоднозначная область важнее спокойного ответа
        log_event(claims, "СВОБОДНО")
        print("держаний нет: файла заявок ещё не заводили (%s)" % claims)
        sys.exit(0)
    if not overridden and not workshop:
        warn.append("ВНИМАНИЕ, корень мастерской вычислен как %s, но это не похоже "
                    "на мастерскую (нет каталога skill-library). Так бывает, когда "
                    "скилл установлен копией (~/.claude/skills/pf-handoff/…): место "
                    "скрипта до мастерской не ведёт. Задай TOOLS один раз — "
                    "TOOLS=<твоя мастерская> claims-check.sh <область> — или "
                    "CLAIMS_FILE прямо на файл заявок; файл заявок искался по пути %s"
                    % (tools, claims))
    elif overridden:
        warn.append("ВНИМАНИЕ, файла заявок нет по пути %s, а он задан вручную "
                    "(%s) — перекрытая переменная запросто указывает на чужой "
                    "проект, где .agents/runtime тоже есть. Проверь путь; если "
                    "мастерская правда новая — заведи файл (touch %s)"
                    % (claims, tools_src, claims))
    else:
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


LIST_MARKER_RE = re.compile(r"^\s*[-*]\s+")


def claim_fields(line):
    """Единый разбор строки заявки для живой проверки И свипа: необязательный
    маркер списка `- ` перед областью снимается, дальше поля через ` · `.
    Одна функция на оба места нарочно: на финале 19.09 живая проверка брала
    первое поле как есть, `- optimize/SPEC.md` канонизировалось в несуществующий
    путь и давало тихое СВОБОДНО поверх живой заявки, которую свип видел."""
    return LIST_MARKER_RE.sub("", line, count=1).split(" · ")


def claim_released(fields):
    """Поле `СНЯТО`/`СНЯТА` после пятого — заявка снята руками: для свипа она
    не «протухла», для живой проверки она свободна (не ЗАНЯТО)."""
    return any(f.strip().startswith(("СНЯТО", "СНЯТА")) for f in fields[5:])


def claim_expiry(line):
    """Строка формата заявки (в любом месте файла) → (срок «истекает», снята
    ли руками), иначе None. Маркер списка `- ` перед строкой допускается
    (claim_fields), разбор смотрит только на пятое поле. Поле
    `СНЯТО`/`СНЯТА` дальше по строке — заявка уже снята руками, свипу она не
    принадлежит (переносить её как «протухла» — ложь), но в отчёте считается
    отдельно, чтобы хвост был виден человеку."""
    fields = claim_fields(line)
    if len(fields) < 5:
        return None
    expires = fields[4].strip()
    if not expires.startswith("истекает "):
        return None
    expires = expires[len("истекает "):]
    if not DATE_RE.match(expires):
        return None
    try:
        datetime.strptime(expires, "%Y-%m-%d %H:%M")
    except ValueError:
        return None
    return expires, claim_released(fields)


# Срок с хвостом после даты (Codex пишет пояс: `… 18:15 WEST`, `истекает: …`;
# бывает дата без времени) — не по форме. Молча считать такую строку живой или
# мёртвой нельзя, держать ВНИМАНИЕ вечно на сотнях старых строк — шум. Пояс
# сдвигает срок не больше чем на 26 ч: прошёл больше — строка истекла.
LOOSE_EXPIRY_RE = re.compile(r"^истекает:?\s*(\d{4}-\d{2}-\d{2})(?:[ T](\d{2}:\d{2}))?")


def loose_expired(field):
    m = LOOSE_EXPIRY_RE.match(field.strip())
    if not m:
        return False
    try:
        t = datetime.strptime("%s %s" % (m.group(1), m.group(2) or "23:59"), "%Y-%m-%d %H:%M")
    except ValueError:
        return False
    return t + timedelta(hours=26) <= datetime.now()


ANNOT_RE = re.compile(r"\s+\([^(){}]*\)\s*$")   # хвост-пометка «(ветка …)»
GLOB_RE = re.compile(r"[*?\[]")


def split_top(s, sep):
    """Деление по sep только вне скобок {} и (); None — скобки не сходятся."""
    out, depth, cur, i = [], 0, "", 0
    while i < len(s):
        ch = s[i]
        if depth == 0 and s.startswith(sep, i):
            out.append(cur); cur = ""; i += len(sep); continue
        if ch in "{(":
            depth += 1
        elif ch in "})":
            depth -= 1
            if depth < 0:
                return None
        cur += ch; i += 1
    if depth:
        return None
    out.append(cur)
    return out


def brace_expand(s):
    """`a/{b,c/{d,e}}` → [a/b, a/c/d, a/c/e] как в shell; None — не разобрать."""
    i = s.find("{")
    if i < 0:
        return None if "}" in s else [s]
    depth = 0
    for j in range(i, len(s)):
        depth += (s[j] == "{") - (s[j] == "}")
        if depth == 0:
            break
    else:
        return None
    parts = split_top(s[i + 1:j], ",")
    if parts is None:
        return None
    out = []
    for part in parts:
        sub = brace_expand(s[:i] + part.strip() + s[j + 1:])
        if sub is None:
            return None
        out.extend(sub)
    return out


def expand_scope(scope):
    """Составная область → перечень путей; None — не разобрать (ВНИМАНИЕ)."""
    out = []
    for part in split_top(scope, " + ") or [None]:
        if part is None:
            return None
        part = ANNOT_RE.sub("", part.strip())
        items = []
        for chunk in split_top(part, ", ") or [None]:
            if chunk is None:
                return None
            sub = brace_expand(chunk.strip())
            if sub is None:
                return None
            items.extend(sub)
        for it in items:
            it = ANNOT_RE.sub("", it.strip())
            m = GLOB_RE.search(it)
            if m:
                it = os.path.dirname(it[:m.start()])
            if not it.strip():
                return None
            out.append(it)
    return out


def sweep_run():
    """--sweep: отчёт о протухших по всему файлу от первого `## `-заголовка
    (шапка — проза с примерами формата, пример с реальной датой не должен
    уехать в архив); с --yes — перенос в архив."""
    stale = []      # (индекс строки, срок)
    looked = 0
    released_expired = 0
    started = False
    for idx, line in enumerate(lines):
        if not started:
            started = line.startswith("## ")
            if not started:
                continue
        parsed = claim_expiry(line)
        if parsed is None:
            continue
        expires, released = parsed
        if released:
            if expires <= now:
                released_expired += 1
            continue
        looked += 1
        if expires <= now:   # та же граница, что у живой проверки
            stale.append((idx, expires))
    if not started:
        warn.append("ВНИМАНИЕ, в файле нет ни одного `## `-заголовка — свипу не с чего "
                    "начать (шапка не сканируется), проверь файл глазами")
        finish()
    for idx, expires in stale:
        print("ПРОТУХЛА %s: %s" % (expires, lines[idx]))
    print("строк формата заявки просмотрено: %d (весь файл от первого «## », кроме снятых)"
          % looked)
    print("снятых руками и истёкших: %d — свип их не трогает, можно удалить руками"
          % released_expired)
    print("протухших: %d" % len(stale))
    if not yes:
        if stale:
            print("файл не тронут; перенести в %s — повтори с --yes (подтверждает человек)"
                  % ARCHIVE_NAME)
        sys.exit(0)
    if not stale:
        print("переносить нечего, файл не тронут")
        sys.exit(0)
    archive = os.path.join(os.path.dirname(claims), ARCHIVE_NAME)
    stale_idx = set(idx for idx, _ in stale)
    kept = [l for i, l in enumerate(lines) if i not in stale_idx]
    already = set()   # строки, которые в архиве уже есть (упавший прошлый перенос)
    try:
        if os.path.islink(archive) or os.path.islink(claims):
            raise OSError("%s или %s — симлинк, не пишу" % (archive, claims))
        if os.path.isfile(archive):
            with open(archive, encoding="utf-8", errors="replace") as fh:
                arch_text = fh.read()
            if ARCHIVE_SECTION not in arch_text.split("\n"):
                arch_text = arch_text.rstrip("\n") + "\n\n" + ARCHIVE_SECTION + "\n"
            if not arch_text.endswith("\n"):
                arch_text += "\n"
            # Перенос идёт в два файла и не атомарен: архив записан, а замена
            # claims.md упала → строки в обоих. Следующий --yes не должен
            # дописать их второй раз: строка, уже лежащая в архиве (без
            # хвоста « · протухла …»), только удаляется из claims.md.
            for arch_line in arch_text.split("\n"):
                head, sep, _ = arch_line.rpartition(" · протухла ")
                if sep:
                    already.add(head)
        else:
            arch_text = ("# Архив заявок (перенесено claims-check.sh --sweep --yes)\n\n"
                         "Протухшие строки из claims.md; к каждой дописано "
                         "` · протухла <когда перенесена>`. Только история, "
                         "проверка живых заявок сюда не смотрит.\n\n"
                         + ARCHIVE_SECTION + "\n")
        moved = ["%s · протухла %s" % (lines[idx], now)
                 for idx, _ in stale if lines[idx] not in already]
        if moved:
            arch_text += "\n".join(moved) + "\n"
        tmp = archive + ".tmp.%d" % os.getpid()
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(arch_text)
        os.replace(tmp, archive)
        tmp = claims + ".tmp.%d" % os.getpid()
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write("\n".join(kept))
        os.replace(tmp, claims)
    except OSError as exc:
        warn.append("ВНИМАНИЕ, перенос не выполнен (%s) — файлы проверь глазами" % exc)
        finish()
    log_event(claims, "СВИП: перенесено %d в %s" % (len(stale), ARCHIVE_NAME))
    print("перенесено в %s: %d (уже были в архиве, только удалены из claims.md: %d)"
          % (archive, len(moved), len(stale) - len(moved)))
    sys.exit(0)


if sweep:
    sweep_run()

live = False
seen = False
started = False   # шапка до первого «## » — проза с примерами формата, не заявки

for line in lines:
    # Заголовок сверяется ДОСЛОВНО: «## Живые заявки (архив)» — уже не живая
    # секция (её отсутствие — ВНИМАНИЕ ниже), строки под ним проверяются как
    # под любым чужим заголовком.
    if line.strip() == SECTION:
        live, seen, started = True, True, True
        continue
    if line.startswith("## "):
        live, started = False, True
        continue
    if not started or not line.strip():
        continue

    fields = claim_fields(line)
    # T-156: под чужим заголовком (сессии, «## Архив») заявка — строка с
    # пятым полем «истекает …»; строка без «истекает» — проза (без срока это
    # не заявка, а таких исторических записей в файле десятки). Слово
    # «истекает» не на своём месте (пропущено поле) — битая заявка: ВНИМАНИЕ,
    # если она не снята и её срок не прошёл давно. В живой секции заявкой
    # обязана быть каждая строка.
    if not live and (len(fields) < 5 or not fields[4].strip().startswith("истекает")):
        # Слово «истекает» в прозе без даты («истекает после ревью») — не
        # заявка: такая строка не протухла бы никогда (💭4 ревью).
        if (re.search(r"истекает:?\s*\d{4}-\d{2}-\d{2}", line)
                and not any(loose_expired(f) for f in fields)
                and not any(f.strip().startswith(("СНЯТО", "СНЯТА")) for f in fields)):
            warn.append("ВНИМАНИЕ, строка не разобрана (проверь глазами): " + line)
        continue
    if len(fields) < 5:
        warn.append("ВНИМАНИЕ, строка не разобрана (проверь глазами): " + line)
        continue
    if claim_released(fields):
        # Снята руками (поле `СНЯТА`/`СНЯТО`) — свободна, как и для свипа:
        # раньше живая проверка отвечала на такую строку ЗАНЯТО (финал 19.09).
        continue

    scope, expires = fields[0], re.sub(r"^истекает ", "", fields[4])

    # Форма проверяется регекспом, календарь — strptime: «2026-13-40 25:61»
    # регексп проходит, а такой даты не бывает, и живой её считать нельзя.
    if not DATE_RE.match(expires):
        if loose_expired(fields[4]):
            continue   # хвост после давно прошедшего срока — истекла
        warn.append("ВНИМАНИЕ, срок не разобран, нужно YYYY-MM-DD HH:MM: " + line)
        continue
    try:
        datetime.strptime(expires, "%Y-%m-%d %H:%M")
    except ValueError:
        warn.append("ВНИМАНИЕ, такой даты нет в календаре: " + line)
        continue
    if expires <= now:
        # Протухшая заявка свободна и молчит: брошенная строка не имеет права
        # блокировать работу навсегда.
        continue

    if not scope.strip():
        warn.append("ВНИМАНИЕ, в строке пустая область (первое поле): " + line)
        continue
    # Составная разворачивается только у живой строки: истёкшие и снятые
    # (их в файле сотни) не живые и молчат. Каждый путь — как отдельная заявка.
    paths = expand_scope(scope)
    if paths is None:
        warn.append("ВНИМАНИЕ, составная область не разобрана (скобки не сходятся) — "
                    "разбери глазами: " + line)
        continue

    try:
        claim_forms = [f for one in paths for f in canon(one)[0]]
    except (OSError, ValueError) as exc:
        warn.append("ВНИМАНИЕ, область заявки не разобрана (%s): %s" % (exc, line))
        continue

    if any_overlap(scope_forms, claim_forms):
        # sid решает только у пересёкшейся строки: битый токен здесь — не
        # «своя» и не «чужая» наугад, а ВНИМАНИЕ (💭5: у непересекающейся
        # строки он ничего не решает и не должен будить все проверки).
        claim_sid, sid_err = line_sid(fields[2])
        if sid_err:
            warn.append("ВНИМАНИЕ, %s: %s" % (sid_err, line))
            continue
        if my_sid and claim_sid == my_sid:
            own.append("СВОБОДНО (своя): " + line)
            continue
        busy.append("ЗАНЯТО: " + line)

if not seen:
    warn.append("ВНИМАНИЕ, секция «%s» не найдена — проверь файл глазами" % SECTION)

if not busy and not warn:
    if own:
        print("СВОБОДНО: с «%s» пересекаются только заявки моей сессии (sid:%s)"
              % (raw_scope, my_sid))
    else:
        print("СВОБОДНО: живых заявок, пересекающихся с «%s», нет" % raw_scope)

finish()
PYEOF
