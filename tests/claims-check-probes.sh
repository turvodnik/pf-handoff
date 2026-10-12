#!/usr/bin/env bash
# claims-check-probes.sh — враждебные пробы для claims-check.sh
# (протокол параллельных сессий, §8; скрипт-канон —
# skill-library/skills/pf-handoff/scripts/claims-check.sh).
#
# Зачем отдельный файл: «проверка ловит алиасы путей» без прогона — это
# утверждение из task-пакета, а не факт. Четыре круга гейта §6 возвращали
# T-030 за один и тот же класс — тихое «свободно» поверх живой заявки, каждый
# раз через НОВУЮ форму того же пути. Здесь этот класс закрыт батареей.
#
# Использование: claims-check-probes.sh [путь-к-claims-check.sh]
#   Аргумент нужен для мутационного контроля: подсовываем СЛОМАННУЮ копию
#   скрипта и убеждаемся, что батарея краснеет (иначе она ничего не проверяет).
# Пишет только в свой mktemp-каталог; боевой claims.md не трогает.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${1:-$TESTS_DIR/../skills/pf-handoff/scripts/claims-check.sh}"
[ -f "$SCRIPT" ] || { echo "ОШИБКА: не найден проверяемый скрипт: $SCRIPT" >&2; exit 2; }
# Абсолютизируем: часть проб запускает скрипт из ЧУЖОГО текущего каталога
# (прочтение относительного пути), и относительный путь к нему там не найдётся.
SCRIPT="$(cd "$(dirname "$SCRIPT")" && pwd)/$(basename "$SCRIPT")"

WORK="$(mktemp -d)"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
PROJ="$WORK/projects"
TOOLS="$PROJ/_tools"
# Экспортируем один раз здесь: пробы ниже запускают "$SCRIPT" как ДОЧЕРНИЙ
# процесс и полагаются на то, что его $TOOLS совпадает со значением,
# подставленным в АРГУМЕНТЫ той же команды. Присваивание вида
# `bash … "$TOOLS/…"` этого НЕ гарантирует (SC2097/2098):
# `"$TOOLS"` в аргументах раскрывает родитель ДО форка, а само присваивание
# видно только форкнутому процессу — в окружении без унаследованного TOOLS
# это разошлось бы молча. Экспорт делает значение видимым потомку без
# зависимости от одноимённого присваивания на той же строке.
export TOOLS
CLAIMS="$TOOLS/.agents/runtime/claims.md"

# T-040 фикс-круг 1, P2: событийный лог не должен попадать в БОЕВОЙ
# claims-events.log ни при каких обстоятельствах, включая пробы, где TOOLS
# намеренно неверен/не задан (`env -u TOOLS`) — там вычисление корня само
# по себе часть проверяемого поведения, и полагаться на него для изоляции
# нельзя. CLAIMS_LOG экспортируется на ВЕСЬ процесс батареи и перекрывает
# вычисление пути лога безусловно (см. `log_path_for()` в claims-check.sh) —
# так утечка тестового события в боевой журнал структурно исключена, а не
# «обычно не происходит».
export CLAIMS_LOG="$WORK/проб-events.log"

pass=0; fail=0

# I-037: перед КАЖДОЙ записью убеждаемся, что цель не симлинк — иначе тест
# пишет мимо своей песочницы, в подменённый файл.
w() {
    [ -L "$1" ] && { echo "ОТКАЗ: $1 — симлинк, не пишу" >&2; exit 9; }
    cat > "$1"
}
mk() {
    [ -L "$1" ] && { echo "ОТКАЗ: $1 — симлинк, не создаю" >&2; exit 9; }
    mkdir -p "$1"
}

mk "$TOOLS/.agents/runtime"
mk "$PROJ/optimize"

FUTURE="2036-01-01 00:00"
PAST="2020-01-01 00:00"

# claims <строки…> — переписать секцию живых заявок фикстуры
claims() {
    { printf '# фикстура\n\n## Живые заявки\n\n'
      for line in "$@"; do printf '%s\n' "$line"; done
    } | w "$CLAIMS"
}

# check <имя> <ожидаемое: ЗАНЯТО|СВОБОДНО|ВНИМАНИЕ> <область> [доп. env]
check() {
    local name="$1" want="$2" scope="$3"
    local out rc state
    out="$(bash "$SCRIPT" "$scope" 2>&1)"; rc=$?
    case "$rc" in
        0) state="СВОБОДНО" ;;
        1) state="ЗАНЯТО" ;;
        2) state="ВНИМАНИЕ" ;;
        *) state="rc=$rc" ;;
    esac
    # Состояние обязано совпадать И с кодом выхода, И с текстом: код без
    # текста (или наоборот) — это ровно тот разъезд, из-за которого «тихо»
    # четыре раза читалось как «свободно».
    if [ "$state" = "$want" ] && printf '%s' "$out" | grep -q "$want\|держаний нет"; then
        pass=$((pass + 1)); printf '  ✅ %-52s → %s\n' "$name" "$state"
    else
        fail=$((fail + 1))
        printf '  ❌ %-52s → ожидалось %s, получено %s\n' "$name" "$want" "$state"
        printf '     вывод: %s\n' "$(printf '%s' "$out" | head -2)"
    fi
}

# checkc — то же, но из ЗАДАННОГО текущего каталога и с проверкой доп. текста:
# checkc <имя> <ожидаемое> <каталог> <область> [обязательная подстрока]
checkc() {
    local name="$1" want="$2" dir="$3" scope="$4" also="${5-}"
    local out rc state
    out="$(cd "$dir" && bash "$SCRIPT" "$scope" 2>&1)"; rc=$?
    case "$rc" in
        0) state="СВОБОДНО" ;;
        1) state="ЗАНЯТО" ;;
        2) state="ВНИМАНИЕ" ;;
        *) state="rc=$rc" ;;
    esac
    if [ "$state" = "$want" ] && printf '%s' "$out" | grep -q "$want" \
       && { [ -z "$also" ] || printf '%s' "$out" | grep -q "$also"; }; then
        pass=$((pass + 1)); printf '  ✅ %-52s → %s\n' "$name" "$state"
    else
        fail=$((fail + 1))
        printf '  ❌ %-52s → ожидалось %s%s, получено %s\n' "$name" "$want" \
               "${also:+ + ${also}}" "$state"
        printf '     вывод: %s\n' "$(printf '%s' "$out" | head -2)"
    fi
}

echo "# claims-check-probes · $SCRIPT"
echo "  песочница: $WORK"
echo

# ---------------------------------------------------------------- алиасы пути
echo "-- батарея алиасов: одна и та же живая заявка, разные формы области --"
claims "_tools/AGENTS.md · T-000 · другая сессия · взято 2026-01-01 00:00 · истекает $FUTURE"

check "абсолютный путь"                    ЗАНЯТО "$TOOLS/AGENTS.md"
check "относительный от папки проектов"    ЗАНЯТО "_tools/AGENTS.md"
check "переход вверх-вниз (..)"            ЗАНЯТО "$TOOLS/../_tools/AGENTS.md"
check "текущий каталог (./)"               ЗАНЯТО "$TOOLS/./AGENTS.md"
check "двойные слэши"                      ЗАНЯТО "$TOOLS//AGENTS.md"
check "подпуть (заявка на каталог выше)"   ЗАНЯТО "$TOOLS"
check "надпуть: репозиторий целиком"       ЗАНЯТО "$PROJ/_tools"

# симлинк на папку проектов
ln -s "$PROJ" "$WORK/ссылка"
check "симлинк на папку проектов"          ЗАНЯТО "$WORK/ссылка/_tools/AGENTS.md"

# путь длиннее 300 символов (через ../ — реальный каталог создавать не нужно)
LONG="$TOOLS"; for _ in $(seq 1 30); do LONG="$LONG/каталог-подлиннее/.."; done
LONG="$LONG/AGENTS.md"
printf '  (длина пробы: %s символов)\n' "${#LONG}"
check "путь длиннее 300 символов"          ЗАНЯТО "$LONG"

# хвостовой слэш — с ОБЕИХ сторон (проба закрывающего гейта)
claims "_tools/ · T-000 · другая сессия · взято 2026-01-01 00:00 · истекает $FUTURE"
check "хвостовой слэш в ЗАЯВКЕ"            ЗАНЯТО "$TOOLS/AGENTS.md"
check "хвостовой слэш в ОБЛАСТИ"           ЗАНЯТО "$TOOLS/"

# ~ в заявке: HOME подменяем на папку проектов фикстуры
# shellcheck disable=SC2088  # `~` тут НЕ должен раскрываться: это форма записи внутри строки заявки, её разворачивает сам скрипт
claims "~/_tools/AGENTS.md · T-000 · другая сессия · взято 2026-01-01 00:00 · истекает $FUTURE"
out="$(HOME="$PROJ" bash "$SCRIPT" "$TOOLS/AGENTS.md" 2>&1)"; rc=$?
if [ $rc -eq 1 ]; then pass=$((pass+1)); printf '  ✅ %-52s → ЗАНЯТО\n' "~ в заявке (было ВНИМАНИЕ в круге 3)"
else fail=$((fail+1)); printf '  ❌ %-52s → rc=%s: %s\n' "~ в заявке" "$rc" "$(printf '%s' "$out" | head -1)"; fi

# пробел и кириллица в разных регистрах
mk "$PROJ/optimize/.agents"
claims "optimize/.agents/Журнал Решений · T-000 · другая сессия · взято 2026-01-01 00:00 · истекает $FUTURE"
FOLDED="$(python3 -c 'import os,sys; p=sys.argv[1]; a=os.path.join(os.path.dirname(p),os.path.basename(p).swapcase()); print("1" if os.path.exists(a) and os.path.samefile(a,p) else "0")' "$TOOLS" 2>/dev/null || echo 0)"
if [ "$FOLDED" = "1" ]; then
    check "кириллица, другой регистр (ФС нечувствительна)" ЗАНЯТО "$PROJ/optimize/.agents/журнал решений"
else
    check "кириллица, другой регистр (ФС ЧУВСТВИТЕЛЬНА)"   СВОБОДНО "$PROJ/optimize/.agents/журнал решений"
fi
check "пробел и кириллица, точное совпадение"             ЗАНЯТО "$PROJ/optimize/.agents/Журнал Решений"

# Форма Unicode: NFD в заявке против NFC в области — один и тот же файл.
# Слово обязано СОДЕРЖАТЬ разложимые буквы (`й` = и + U+0306, `ё` = е + U+0308):
# на «Журнал» проба была бы декоративной — NFD его не меняет, и она проходила
# бы даже у скрипта без нормализации (поймано мутационным контролем).
NFD="$(python3 -c 'import unicodedata; print(unicodedata.normalize("NFD","optimize/.agents/Найдённый-й"))')"
NFC="$(python3 -c 'import unicodedata; print(unicodedata.normalize("NFC","Найдённый-й"))')"
[ "$NFD" != "optimize/.agents/$NFC" ] || { echo "ОШИБКА: проба NFD/NFC вырождена — формы совпали" >&2; exit 3; }
claims "$NFD · T-000 · другая сессия · взято 2026-01-01 00:00 · истекает $FUTURE"
check "NFD в заявке ↔ NFC в области"       ЗАНЯТО "$PROJ/optimize/.agents/$NFC"

echo
echo "-- относительный путь: от папки проектов ИЛИ от текущего каталога --"
# Класс не «две записи одного пути не совпали» (он закрыт канонизацией), а
# обратный: ОДНА запись означает два разных пути. Файл заявок отсчитывает
# относительный путь от папки проектов, человек в оболочке — от текущего
# каталога. Молча выбрать одно прочтение = тихое «свободно» поверх живой
# заявки (проба закрывающего гейта §6, 14.08, на боевом файле).
mk "$PROJ/проект/seo"
claims "проект/seo · T-000 · другая сессия · взято 2026-01-01 00:00 · истекает $FUTURE"
checkc "из проекта: «seo» поверх живой заявки"      ЗАНЯТО   "$PROJ/проект" "seo"        "ВНИМАНИЕ"
checkc "из проекта: «./seo/reports» (подпуть)"      ЗАНЯТО   "$PROJ/проект" "./seo/reports" "ВНИМАНИЕ"
checkc "контроль: тот же путь абсолютным"           ЗАНЯТО   "$PROJ/проект" "$PROJ/проект/seo"
checkc "неоднозначный, но пересечений нет"          ВНИМАНИЕ "$PROJ/проект" "нет-такого"
checkc "из папки проектов: прочтение одно"          ЗАНЯТО   "$PROJ"        "проект/seo"
checkc "из папки проектов: сосед свободен"          СВОБОДНО "$PROJ"        "проект/seo-old"
checkc "«.» из проекта: неоднозначна и громкая"     ЗАНЯТО   "$PROJ/проект" "."          "ВНИМАНИЕ"

echo
echo "-- отрицательные контроли: похоже, но НЕ пересекается --"
claims "_tools/AGENTS.md · T-000 · другая сессия · взято 2026-01-01 00:00 · истекает $FUTURE"
check "сосед по имени (AGENTS.md.bak)"     СВОБОДНО "$TOOLS/AGENTS.md.bak"
check "соседний репозиторий"               СВОБОДНО "$PROJ/optimize/SPEC.md"
claims "_tools/security · T-000 · другая сессия · взято 2026-01-01 00:00 · истекает $FUTURE"
check "граница префикса (security-notes.md)" СВОБОДНО "$TOOLS/security-notes.md"
check "внутри заявленного каталога"        ЗАНЯТО   "$TOOLS/security/gitleaks.py"
claims "_tools/AGENTS.md · T-000 · другая сессия · взято 2026-01-01 00:00 · истекает $PAST"
check "протухшая + абсолютная форма"       СВОБОДНО "$TOOLS/AGENTS.md"
# shellcheck disable=SC2088  # `~` тут НЕ должен раскрываться: это форма записи внутри строки заявки, её разворачивает сам скрипт
claims "~/_tools/AGENTS.md · T-000 · другая сессия · взято 2026-01-01 00:00 · истекает $PAST"
check "протухшая + ~ (канонизация не воскрешает)" СВОБОДНО "$TOOLS/AGENTS.md"

echo
echo "-- регресс кругов 1-4: «не смог проверить» обязано быть громким --"
claims "_tools/a + _tools/b · T-000 · кто · взято 2026-01-01 00:00 · истекает $FUTURE"
# Фикс-раунд 1 T-156: составная разворачивается — вторая половина занята.
check "составная область (круг 1)"         ЗАНЯТО   "$TOOLS/b"
claims "_tools/AGENTS.md·T-000·кто·взято 2026-01-01 00:00·истекает $FUTURE"
check "разделитель без пробелов (круг 1)"  ВНИМАНИЕ "$TOOLS/AGENTS.md"
claims "_tools/AGENTS.md · T-000 · кто · взято 14.08.2026 20:55 · истекает 14.08.2026 20:55"
check "дата в чужом формате (круг 2)"      ВНИМАНИЕ "$TOOLS/AGENTS.md"
# T-156: проверка читает весь файл — живая строка под любым заголовком занята;
# пропавшая секция по-прежнему громкая (ЗАНЯТО + «не найдена», раньше — только ВНИМАНИЕ).
{ printf '# фикстура\n\n## Текущие держания\n\n_tools/AGENTS.md · T-000 · кто · взято 2026-01-01 00:00 · истекает %s\n' "$FUTURE"; } | w "$CLAIMS"
checkc "переименованная секция (круг 2)"    ЗАНЯТО "$PROJ" "$TOOLS/AGENTS.md" "не найдена"
printf '' | w "$CLAIMS"
check "пустой файл"                        ВНИМАНИЕ "$TOOLS/AGENTS.md"
claims ""
check "только заголовок секции"            СВОБОДНО "$TOOLS/AGENTS.md"
# CRLF: намеренная смена поведения относительно кругов 1-4. Раньше `\r`
# приклеивался к сроку, срок не разбирался и печаталось ВНИМАНИЕ. Теперь файл
# читается с трансляцией переводов строки, то есть понимается ЦЕЛИКОМ, и живая
# заявка честно даёт ЗАНЯТО. Проверяем именно опасное направление: CRLF не
# должен ПРЯТАТЬ живую заявку (ВНИМАНИЕ тоже было безопасно, ЗАНЯТО — точнее).
printf '# ф\n\n## Живые заявки\n\n_tools/AGENTS.md · T-000 · кто · взято 2026-01-01 00:00 · истекает %s\r\n' "$FUTURE" | w "$CLAIMS"
check "CRLF не прячет живую заявку"        ЗАНЯТО "$TOOLS/AGENTS.md"
printf '# ф\n\n## Живые заявки\n\n_tools/AGENTS.md · T-000 · кто · взято 2026-01-01 00:00 · истекает %s\r\n' "$PAST" | w "$CLAIMS"
check "CRLF + протухшая → свободна"        СВОБОДНО "$TOOLS/AGENTS.md"
# 💭 закрывающего гейта: похожий заголовок — не живая секция (громко: «не найдена»),
# но живая строка под ним занята (T-156); календарно невозможная дата — не живой
# срок; пустая область — не «занято на всё».
{ printf '# ф\n\n## Живые заявки (архив)\n\n_tools/AGENTS.md · T-000 · кто · взято 2026-01-01 00:00 · истекает %s\n' "$FUTURE"; } | w "$CLAIMS"
checkc "«## Живые заявки (архив)» — не секция, строка жива" ЗАНЯТО "$PROJ" "$TOOLS/AGENTS.md" "не найдена"
claims "_tools/AGENTS.md · T-000 · кто · взято 2026-01-01 00:00 · истекает 2026-13-40 25:61"
check "календарно невозможный срок"        ВНИМАНИЕ "$TOOLS/AGENTS.md"
claims " · T-000 · кто · взято 2026-01-01 00:00 · истекает $FUTURE"
check "пустая область в строке заявки"      ВНИМАНИЕ "$PROJ/optimize/SPEC.md"
claims "просто строка прозы внутри секции"
check "проза внутри секции"                ВНИМАНИЕ "$TOOLS/AGENTS.md"
{ printf '# ф\n\n## Живые заявки\n\n## Архив\n\n_tools/AGENTS.md · T-000 · кто · взято 2026-01-01 00:00 · истекает %s\n' "$FUTURE"; } | w "$CLAIMS"
check "живая строка ниже, под ## Архив (T-156)" ЗАНЯТО "$TOOLS/AGENTS.md"
claims "_tools/AGENTS.md · T-000 · кто · взято 2026-01-01 00:00 · истекает $FUTURE"
chmod 000 "$CLAIMS"
check "нечитаемый файл при живой заявке"   ВНИМАНИЕ "$TOOLS/AGENTS.md"
chmod 644 "$CLAIMS"

echo
echo "-- смешанное состояние и пустой ввод --"
claims "битая строка" "_tools/AGENTS.md · T-000 · кто · взято 2026-01-01 00:00 · истекает $FUTURE"
out="$(bash "$SCRIPT" "$TOOLS/AGENTS.md" 2>&1)"; rc=$?
if [ $rc -eq 1 ] && printf '%s' "$out" | grep -q "ЗАНЯТО" && printf '%s' "$out" | grep -q "ВНИМАНИЕ"; then
    pass=$((pass+1)); printf '  ✅ %-52s → ЗАНЯТО (rc=1) + ВНИМАНИЕ напечатано\n' "живая заявка + мусорная строка"
else
    fail=$((fail+1)); printf '  ❌ %-52s → rc=%s, вывод: %s\n' "живая заявка + мусорная строка" "$rc" "$out"
fi
check "область из одних пробелов"          ВНИМАНИЕ "   "
out="$(bash "$SCRIPT" 2>&1)"; rc=$?
if [ $rc -eq 2 ]; then pass=$((pass+1)); printf '  ✅ %-52s → ВНИМАНИЕ (rc=2)\n' "область не задана вовсе"
else fail=$((fail+1)); printf '  ❌ %-52s → rc=%s\n' "область не задана вовсе" "$rc"; fi

echo
echo "-- файла заявок нет / TOOLS уводит не туда --"
rm -f "$CLAIMS"
# Спокойное «держаний нет» допустимо ТОЛЬКО при ВЫЧИСЛЕННОМ корне: копия
# скрипта на штатной глубине внутри фикстуры-мастерской, TOOLS не задан.
mk "$TOOLS/skill-library/skills/pf-handoff/scripts"
cp "$SCRIPT" "$TOOLS/skill-library/skills/pf-handoff/scripts/claims-check.sh"
INNER="$TOOLS/skill-library/skills/pf-handoff/scripts/claims-check.sh"
out="$(env -u TOOLS -u CLAIMS_FILE bash "$INNER" "$TOOLS/AGENTS.md" 2>&1)"; rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q "держаний нет"; then
    pass=$((pass+1)); printf '  ✅ %-52s → держаний нет (rc=0)\n' "файла нет, корень ВЫЧИСЛЕН"
else fail=$((fail+1)); printf '  ❌ %-52s → rc=%s: %s\n' "файла нет, корень вычислен" "$rc" "$(printf '%s' "$out" | head -1)"; fi
# Та же нехватка файла, но корень ПЕРЕКРЫТ руками — спокойно отвечать нельзя.
# Смена ожидания названа явно: раньше здесь было СВОБОДНО. Каталог
# `.agents/runtime` есть по §9 у КАЖДОГО проекта, поэтому `TOOLS=$(pwd)` из
# любого проекта давал спокойное «держаний нет» поверх живых заявок настоящего
# файла (🟡 закрывающего гейта §6, 14.08).
check "файла нет, но TOOLS перекрыт руками"        ВНИМАНИЕ "$TOOLS/AGENTS.md"
# Спокойное «держаний нет» не должно проглатывать неоднозначность области:
# файла нет, корень вычислен — но прочтения относительного пути разошлись.
out="$(cd "$PROJ/проект" && env -u TOOLS -u CLAIMS_FILE bash "$INNER" "seo" 2>&1)"; rc=$?
if [ $rc -eq 2 ]; then pass=$((pass+1)); printf '  ✅ %-52s → ВНИМАНИЕ (rc=2)\n' "файла нет + неоднозначная область"
else fail=$((fail+1)); printf '  ❌ %-52s → rc=%s: %s\n' "файла нет + неоднозначная область" "$rc" "$(printf '%s' "$out" | head -1)"; fi
out="$(CLAIMS_FILE="$TOOLS/нет-такого-файла.md" bash "$SCRIPT" "$TOOLS/AGENTS.md" 2>&1)"; rc=$?
if [ $rc -eq 2 ]; then pass=$((pass+1)); printf '  ✅ %-52s → ВНИМАНИЕ (rc=2)\n' "CLAIMS_FILE перекрыт и указывает мимо"
else fail=$((fail+1)); printf '  ❌ %-52s → rc=%s: %s\n' "CLAIMS_FILE перекрыт и указывает мимо" "$rc" "$(printf '%s' "$out" | head -1)"; fi
# Здесь TOOLS у ребёнка НАМЕРЕННО расходится со значением в аргументе
# ($TOOLS, унаследованный из export выше, — реальный путь фикстуры):
# проверяем, что скрипт замечает битый TOOLS, даже когда аргумент
# указывает на существующий файл. Отдельное имя (BOGUS_TOOLS) вместо
# переприсваивания TOOLS в той же команде — чтобы это расхождение было
# видно по имени переменной, а не пряталось за совпадением имён.
BOGUS_TOOLS="$WORK/нет-такого"
REAL_AGENTS_MD="$TOOLS/AGENTS.md"
out="$(TOOLS="$BOGUS_TOOLS" bash "$SCRIPT" "$REAL_AGENTS_MD" 2>&1)"; rc=$?
if [ $rc -eq 2 ]; then pass=$((pass+1)); printf '  ✅ %-52s → ВНИМАНИЕ (rc=2)\n' "TOOLS мимо (каталога нет)"
else fail=$((fail+1)); printf '  ❌ %-52s → rc=%s: %s\n' "TOOLS мимо" "$rc" "$out"; fi
ln -s "$WORK/в-никуда" "$CLAIMS"
out="$(bash "$SCRIPT" "$TOOLS/AGENTS.md" 2>&1)"; rc=$?
if [ $rc -eq 2 ]; then pass=$((pass+1)); printf '  ✅ %-52s → ВНИМАНИЕ (rc=2)\n' "битый симлинк на файл заявок"
else fail=$((fail+1)); printf '  ❌ %-52s → rc=%s: %s\n' "битый симлинк на файл заявок" "$rc" "$out"; fi
rm -f "$CLAIMS"

# TOOLS не задан вовсе: корень вычисляется из места скрипта. Кладём КОПИЮ
# скрипта туда, где вычисленный корень пуст — ответ обязан быть ВНИМАНИЕ,
# а не успокаивающее «свободно» (класс 🔴 круга 2, закрытый конструкцией).
mk "$WORK/чужое/skills/pf-handoff/scripts"
cp "$SCRIPT" "$WORK/чужое/skills/pf-handoff/scripts/claims-check.sh"
out="$(env -u TOOLS -u CLAIMS_FILE bash "$WORK/чужое/skills/pf-handoff/scripts/claims-check.sh" "$TOOLS/AGENTS.md" 2>&1)"; rc=$?
if [ $rc -eq 2 ]; then pass=$((pass+1)); printf '  ✅ %-52s → ВНИМАНИЕ (rc=2)\n' "TOOLS не задан, вычисленный корень пуст"
else fail=$((fail+1)); printf '  ❌ %-52s → rc=%s: %s\n' "TOOLS не задан, корень пуст" "$rc" "$out"; fi

# Тот же класс, но в форме, которую получает ЧУЖОЙ пользователь дистрибутива
# (🟡 независимого QA v1.10.0): установщик кладёт скилл КОПИЕЙ в
# ~/.claude/skills/pf-handoff/, симлинк-цепочки нет, и «четыре уровня вверх»
# дают корень = $HOME. Если у человека при этом есть ~/.agents/runtime (у
# пользователя глобального канона он заводится сам), прежний код отвечал
# спокойным «держаний нет» — успокоение поверх заведомо неверного корня, то
# самое «не смог проверить» под видом «проверил, чисто». Отличие от пробы выше
# ровно одно: каталог .agents/runtime на месте, признака мастерской нет.
mk "$WORK/домашний/.claude/skills/pf-handoff/scripts"
mk "$WORK/домашний/.agents/runtime"
cp "$SCRIPT" "$WORK/домашний/.claude/skills/pf-handoff/scripts/claims-check.sh"
out="$(env -u TOOLS -u CLAIMS_FILE bash "$WORK/домашний/.claude/skills/pf-handoff/scripts/claims-check.sh" "$TOOLS/AGENTS.md" 2>&1)"; rc=$?
if [ $rc -eq 2 ] && printf '%s' "$out" | grep -q "не похоже"; then
    pass=$((pass+1)); printf '  ✅ %-52s → ВНИМАНИЕ (rc=2)\n' "скилл копией в ~/.claude, есть .agents/runtime"
else fail=$((fail+1)); printf '  ❌ %-52s → rc=%s: %s\n' "скилл копией в ~/.claude, есть .agents/runtime" "$rc" "$(printf '%s' "$out" | head -1)"; fi

# Положительная сторона того же: копия скрипта лежит на ШТАТНОЙ глубине
# (skill-library/skills/pf-handoff/scripts/) внутри фикстуры-мастерской, TOOLS
# не задан — корень обязан вычислиться верно и найти живую заявку. Без этой
# пробы сломанное вычисление глубины проходило бы батарею: «мимо» — это тоже
# ВНИМАНИЕ, и отрицательная проба его не отличает.
claims "_tools/AGENTS.md · T-000 · другая сессия · взято 2026-01-01 00:00 · истекает $FUTURE"
out="$(env -u TOOLS -u CLAIMS_FILE bash "$INNER" "$TOOLS/AGENTS.md" 2>&1)"; rc=$?
if [ $rc -eq 1 ]; then pass=$((pass+1)); printf '  ✅ %-52s → ЗАНЯТО\n' "TOOLS не задан, корень вычислен верно"
else fail=$((fail+1)); printf '  ❌ %-52s → rc=%s: %s\n' "TOOLS не задан, корень вычислен верно" "$rc" "$out"; fi

echo
echo "-- событийный лог (T-040, фикс-круги 1-2) --"

# P2/изоляция: CLAIMS_LOG (уже экспортирован на всю батарею) обязан
# перекрывать вычисление пути лога БЕЗУСЛОВНО, даже когда TOOLS корректен, —
# иначе изоляция песочницы от боевого журнала держится на совпадении, а не
# на договоре.
rm -f "$CLAIMS_LOG"
claims "_tools/лог-проба · T-000 · кто · взято 2026-01-01 00:00 · истекает $FUTURE"
out="$(bash "$SCRIPT" "$TOOLS/лог-проба" 2>&1)"; rc=$?
if [ $rc -eq 1 ] && [ -f "$CLAIMS_LOG" ] && [ "$(wc -l < "$CLAIMS_LOG" | tr -d ' ')" = 1 ]; then
    pass=$((pass+1)); printf '  ✅ %-52s → CLAIMS_LOG перекрывает путь, 1 строка\n' "лог: CLAIMS_LOG обязателен для теста"
else
    fail=$((fail+1)); printf '  ❌ %-52s → rc=%s, файл=%s\n' "лог: CLAIMS_LOG" "$rc" "$([ -f "$CLAIMS_LOG" ] && echo да || echo нет)"
fi

# P3 (💭, разрыв строки): область и CLAIMS_ACTOR с буквальным переводом
# строки — одно событие обязано остаться ОДНОЙ строкой лога, иначе свип
# считает одно взятие заявки за два и больше события.
rm -f "$CLAIMS_LOG"
out="$(CLAIMS_ACTOR=$'сессия\nвторая-строка' bash "$SCRIPT" "$TOOLS/лог-проба"$'\n'"-перенос" 2>&1)"; rc=$?
after_lines=$(wc -l < "$CLAIMS_LOG" 2>/dev/null | tr -d ' ')
if [ "${after_lines:-0}" = 1 ] && ! grep -qP '\r' "$CLAIMS_LOG" 2>/dev/null; then
    pass=$((pass+1)); printf '  ✅ %-52s → 1 строка на событие, перенос не пролез\n' "лог: перевод строки в области/CLAIMS_ACTOR"
else
    fail=$((fail+1)); printf '  ❌ %-52s → строк в логе: %s (ожидалась 1)\n' "лог: перевод строки" "${after_lines:-0}"
    printf '     содержимое: %s\n' "$(cat "$CLAIMS_LOG" 2>/dev/null)"
fi

# Каталог под лог ещё не существует (левый TOOLS, `.agents/` там и не
# заводили) — claims-check.sh никогда не создаёт его сам только ради лога,
# ни здесь, ни в любом другом сценарии.
BOGUS="$WORK/левый-корень"
mk "$BOGUS"
out="$(env -u CLAIMS_LOG TOOLS="$BOGUS" bash "$SCRIPT" "$BOGUS/AGENTS.md" 2>&1)"; rc=$?
if [ $rc -eq 2 ] && [ ! -e "$BOGUS/.agents" ]; then
    pass=$((pass+1)); printf '  ✅ %-52s → ВНИМАНИЕ, .agents/ не создан\n' "лог: не создаёт каталог в непроверенном корне"
else
    fail=$((fail+1)); printf '  ❌ %-52s → rc=%s, .agents/ существует=%s\n' "лог: не создаёт каталог" "$rc" "$([ -e "$BOGUS/.agents" ] && echo да || echo нет)"
fi

echo
echo "-- sid: заявка = сессия (T-122, I-066) --"

# checkx <имя> <ожидаемое> <обязательная подстрока> <аргументы скрипта…>
# Как check, но принимает флаги (--sid, --sweep) и требует подстроку в выводе:
# «СВОБОДНО (своя)» и «СВОБОДНО» дают один код 0, различить их может только
# текст.
checkx() {
    local name="$1" want="$2" also="$3"; shift 3
    local out rc state
    out="$(bash "$SCRIPT" "$@" 2>&1)"; rc=$?
    case "$rc" in
        0) state="СВОБОДНО" ;;
        1) state="ЗАНЯТО" ;;
        2) state="ВНИМАНИЕ" ;;
        *) state="rc=$rc" ;;
    esac
    if [ "$state" = "$want" ] && printf '%s' "$out" | grep -q "$want" \
       && printf '%s' "$out" | grep -qF -- "$also"; then
        pass=$((pass + 1)); printf '  ✅ %-52s → %s\n' "$name" "$state"
    else
        fail=$((fail + 1))
        printf '  ❌ %-52s → ожидалось %s + «%s», получено %s\n' "$name" "$want" "$also" "$state"
        printf '     вывод: %s\n' "$(printf '%s' "$out" | head -2)"
    fi
}

SID_A="1a2b3c4d"; SID_B="deadbeef"
claims "_tools/AGENTS.md · T-000 · claude (pf-executor) sid:$SID_A · взято 2026-01-01 00:00 · истекает $FUTURE"
# Своего sid у проверяющего нет — строка с sid чужая по определению (старое
# поведение: любое живое пересечение занято).
checkx "sid в строке, у проверяющего sid нет" ЗАНЯТО "ЗАНЯТО: _tools/AGENTS.md" "$TOOLS/AGENTS.md"
checkx "тот же sid через --sid" СВОБОДНО "СВОБОДНО (своя): _tools/AGENTS.md" --sid "$SID_A" "$TOOLS/AGENTS.md"
out="$(CLAIMS_SID="$SID_A" bash "$SCRIPT" "$TOOLS/AGENTS.md" 2>&1)"; rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -qF "СВОБОДНО (своя)"; then
    pass=$((pass+1)); printf '  ✅ %-52s → СВОБОДНО (своя)\n' "тот же sid через CLAIMS_SID"
else fail=$((fail+1)); printf '  ❌ %-52s → rc=%s: %s\n' "тот же sid через CLAIMS_SID" "$rc" "$(printf '%s' "$out" | head -1)"; fi
checkx "другой sid → чужая" ЗАНЯТО "ЗАНЯТО: _tools/AGENTS.md" --sid "$SID_B" "$TOOLS/AGENTS.md"
# Флаг важнее переменной: --sid чужой поверх CLAIMS_SID своего — заявка чужая.
out="$(CLAIMS_SID="$SID_A" bash "$SCRIPT" --sid "$SID_B" "$TOOLS/AGENTS.md" 2>&1)"; rc=$?
if [ $rc -eq 1 ]; then pass=$((pass+1)); printf '  ✅ %-52s → ЗАНЯТО\n' "--sid перекрывает CLAIMS_SID"
else fail=$((fail+1)); printf '  ❌ %-52s → rc=%s: %s\n' "--sid перекрывает CLAIMS_SID" "$rc" "$(printf '%s' "$out" | head -1)"; fi
# Свой sid не по форме — ВНИМАНИЕ, а не «чужая» и не «своя» наугад.
checkx "свой sid не по форме (XYZ)" ВНИМАНИЕ "не по форме" --sid XYZ "$TOOLS/AGENTS.md"
checkx "свой sid 7 знаков" ВНИМАНИЕ "не по форме" --sid 1a2b3c4 "$TOOLS/AGENTS.md"
checkx "свой sid верхний регистр" ВНИМАНИЕ "не по форме" --sid 1A2B3C4D "$TOOLS/AGENTS.md"
checkx "свой sid пустой (--sid \"\")" ВНИМАНИЕ "не по форме" --sid "" "$TOOLS/AGENTS.md"
out="$(CLAIMS_SID=" " bash "$SCRIPT" "$TOOLS/AGENTS.md" 2>&1)"; rc=$?
if [ $rc -eq 2 ] && printf '%s' "$out" | grep -q "CLAIMS_SID"; then pass=$((pass+1)); printf '  ✅ %-52s → ВНИМАНИЕ\n' "CLAIMS_SID из пробела"
else fail=$((fail+1)); printf '  ❌ %-52s → rc=%s: %s\n' "CLAIMS_SID из пробела" "$rc" "$(printf '%s' "$out" | head -1)"; fi
# sid в СТРОКЕ не по форме — строка битая, как «срок не разобран»: даже при
# совпадении «по буквам» (XYZ = XYZ) своей она не станет.
claims "_tools/AGENTS.md · T-000 · claude sid:XYZ · взято 2026-01-01 00:00 · истекает $FUTURE"
checkx "sid в строке не по форме" ВНИМАНИЕ "не по форме" "$TOOLS/AGENTS.md"
claims "_tools/AGENTS.md · T-000 · claude sid:1A2B3C4D · взято 2026-01-01 00:00 · истекает $FUTURE"
checkx "sid в строке верхний регистр" ВНИМАНИЕ "не по форме" --sid 1a2b3c4d "$TOOLS/AGENTS.md"
# Старый корпус: строка без sid проходит как раньше — и с заданным своим sid
# она чужая (нет sid ≠ мой sid).
claims "_tools/AGENTS.md · T-000 · другая сессия · взято 2026-01-01 00:00 · истекает $FUTURE"
check  "строка без sid, проверяющий без sid (старый корпус)" ЗАНЯТО "$TOOLS/AGENTS.md"
checkx "строка без sid при своём --sid → чужая" ЗАНЯТО "ЗАНЯТО: _tools/AGENTS.md" --sid "$SID_A" "$TOOLS/AGENTS.md"
# Своя заявка рядом с чужой на тот же путь: чужая побеждает (код 1), но
# своя всё равно названа — обе строки в выводе.
claims "_tools/AGENTS.md · T-000 · claude sid:$SID_A · взято 2026-01-01 00:00 · истекает $FUTURE" \
       "_tools/AGENTS.md · T-001 · claude sid:$SID_B · взято 2026-01-01 00:00 · истекает $FUTURE"
checkx "своя + чужая на один путь → ЗАНЯТО, своя названа" ЗАНЯТО "СВОБОДНО (своя)" --sid "$SID_A" "$TOOLS/AGENTS.md"
# Неизвестный флаг и --yes без --sweep — громко, не «свободно».
checkx "неизвестный флаг --foo" ВНИМАНИЕ "неизвестный аргумент" --foo "$TOOLS/AGENTS.md"
checkx "--yes без --sweep" ВНИМАНИЕ "--yes" --yes "$TOOLS/AGENTS.md"

echo
echo "-- живая проверка читает строку как свип: маркер списка «- », поле СНЯТА (финал 19.09) --"
# Живая секция в реальном файле ведётся списком (`- <scope> · …`); до правки
# живая проверка брала «- optimize/SPEC.md» как путь и молча отвечала
# СВОБОДНО поверх живой заявки, которую свип видел. Разбор теперь один на оба.
SID_C="cccccccc"
claims "- optimize/SPEC.md · T-998 · claude sid:$SID_C · взято 2026-01-01 00:00 · истекает $FUTURE"
checkx "маркер «- », проверяющий без sid → ЗАНЯТО" ЗАНЯТО "ЗАНЯТО: - optimize/SPEC.md" "$PROJ/optimize/SPEC.md"
checkx "маркер «- », чужой sid → ЗАНЯТО" ЗАНЯТО "ЗАНЯТО: - optimize/SPEC.md" --sid "$SID_B" "$PROJ/optimize/SPEC.md"
checkx "маркер «- », свой sid → СВОБОДНО (своя)" СВОБОДНО "СВОБОДНО (своя): - optimize/SPEC.md" --sid "$SID_C" "$PROJ/optimize/SPEC.md"
# Поле СНЯТА после пятого: заявка снята руками — свободна и для живой проверки
# (раньше — ЗАНЯТО; свип такую строку и так не считал протухшей).
claims "_tools/AGENTS.md · T-000 · claude sid:$SID_A · взято 2026-01-01 00:00 · истекает $FUTURE · СНЯТА 2026-01-01 01:00"
checkx "поле СНЯТА → СВОБОДНО" СВОБОДНО "живых заявок" "$TOOLS/AGENTS.md"
claims "- _tools/AGENTS.md · T-000 · claude · взято 2026-01-01 00:00 · истекает $FUTURE · СНЯТО 2026-01-01 01:00 — main abc1234"
checkx "маркер + поле СНЯТО → СВОБОДНО" СВОБОДНО "живых заявок" "$TOOLS/AGENTS.md"
# Негативный контроль: маркер без остальных полей — не заявка, ВНИМАНИЕ, не «свободно».
claims "- _tools/AGENTS.md"
checkx "маркер без полей → ВНИМАНИЕ" ВНИМАНИЕ "не разобрана" "$TOOLS/AGENTS.md"
# Контроль: строка с маркером и живой датой — по-прежнему ЗАНЯТО без sid у обоих.
claims "- _tools/AGENTS.md · T-000 · другая сессия · взято 2026-01-01 00:00 · истекает $FUTURE"
check  "маркер «- », старый корпус без sid → ЗАНЯТО" ЗАНЯТО "$TOOLS/AGENTS.md"

echo
echo "-- весь файл: чужие «## », составные области, срок с хвостом (T-156, Н1 аудита 02.10) --"
# Claude дописывает заявки в конец файла (`>>`) под чужие заголовки сессий; до
# T-156 проверка читала только «## Живые заявки» и отвечала СВОБОДНО над живой
# заявкой. Под чужим заголовком заявкой считается строка с пятым полем
# «истекает …», проза там молчит; шапка до первого «## » — примеры формата.
# claims_below <строки…> — пустая живая секция, ниже чужой заголовок с прозой.
claims_below() {
    { printf '# фикстура\n\nПример в шапке: _tools/AGENTS.md · T · кто · взято 2026-01-01 00:00 · истекает %s\n\n## Живые заявки\n\n' "$FUTURE"
      printf '## Сессия такая-то · claude · 2026-10-02\n\nПроза · с · разделителями · но · без срока\n'
      for line in "$@"; do printf '%s\n' "$line"; done
    } | w "$CLAIMS"
}
claims_below "optimize/ниже · T-900 · claude sid:$SID_A · взято 2026-01-01 00:00 · истекает $FUTURE"
check  "под чужим заголовком, без sid → ЗАНЯТО"        ЗАНЯТО "$PROJ/optimize/ниже/файл.md"
checkx "под чужим заголовком, чужой sid → ЗАНЯТО"       ЗАНЯТО "ЗАНЯТО: optimize/ниже" --sid "$SID_B" "$PROJ/optimize/ниже"
checkx "под чужим заголовком, свой sid → СВОБОДНО (своя)" СВОБОДНО "СВОБОДНО (своя): optimize/ниже" --sid "$SID_A" "$PROJ/optimize/ниже"
check  "шапка с живым сроком и проза под «## » молчат"  СВОБОДНО "$TOOLS/AGENTS.md"
# Составная область: скобки читались как буквальное имя, «{SPEC.md,AUDIT.md}» не
# защищал SPEC.md (аудит 6). Фикс-раунд 1: составная разворачивается в перечень
# путей (« + », хвост «(…)», {a,b} как в shell, «a, b», глоб → каталог), каждый
# проверяется отдельно; ВНИМАНИЕ — только если скобки не сходятся.
claims "optimize/{SPEC.md,AUDIT.md} · T-901 · claude · взято 2026-01-01 00:00 · истекает $FUTURE"
checkx "{…} в живой секции → ЗАНЯТО"                   ЗАНЯТО "ЗАНЯТО: optimize/{SPEC.md" "$PROJ/optimize/SPEC.md"
check  "{…} без пересечения → СВОБОДНО"                СВОБОДНО "$PROJ/optimize/README.md"
claims_below "optimize/{SPEC.md,AUDIT.md} · T-901 · claude · взято 2026-01-01 00:00 · истекает $FUTURE"
checkx "{…} под чужим заголовком → ЗАНЯТО"             ЗАНЯТО "ЗАНЯТО: optimize/{SPEC.md" "$PROJ/optimize/SPEC.md"
claims_below "_tools/a + _tools/b · T-902 · claude · взято 2026-01-01 00:00 · истекает $FUTURE"
checkx "« + » под чужим заголовком → ЗАНЯТО"           ЗАНЯТО "ЗАНЯТО: _tools/a + _tools/b" "$TOOLS/b"
claims_below "optimize/вл/{a/{x.md,y.md},b.md} · T-909 · claude · взято 2026-01-01 00:00 · истекает $FUTURE"
check  "вложенные {…{…}} → ЗАНЯТО"                     ЗАНЯТО "$PROJ/optimize/вл/a/y.md"
claims_below "optimize/спис/a.md, optimize/спис/b.md · T-910 · claude · взято 2026-01-01 00:00 · истекает $FUTURE"
check  "список «a, b» → ЗАНЯТО по второму"             ЗАНЯТО "$PROJ/optimize/спис/b.md"
claims_below "optimize/вет/y.md (ветка wt-1) · T-911 · claude · взято 2026-01-01 00:00 · истекает $FUTURE"
check  "хвост «(ветка …)» → ЗАНЯТО"                    ЗАНЯТО "$PROJ/optimize/вет/y.md"
claims_below "optimize/глоб/отчёт-* · T-912 · claude · взято 2026-01-01 00:00 · истекает $FUTURE"
check  "глоб → свой каталог ЗАНЯТ"                     ЗАНЯТО "$PROJ/optimize/глоб/отчёт-1.md"
claims_below "optimize/скоб/{a.md,b.md · T-913 · claude · взято 2026-01-01 00:00 · истекает $FUTURE"
checkx "незакрытая скобка → ВНИМАНИЕ"                  ВНИМАНИЕ "не разобрана" "$PROJ/optimize/другое"
# sid в скобках пометки «(… sid:1a2b3c4d)» — хвостовая «)» не часть токена.
claims_below "optimize/зонт · T-914 · claude (оркестратор sid:$SID_A) · взято 2026-01-01 00:00 · истекает $FUTURE"
checkx "«sid:…)» в скобках → СВОБОДНО (своя)"          СВОБОДНО "СВОБОДНО (своя)" --sid "$SID_A" "$PROJ/optimize/зонт"
# Битый sid у непересекающейся строки ничего не решает — молчит; у
# пересёкшейся — ВНИМАНИЕ (пробы T-122 выше).
claims_below "optimize/кодекс · T-915 · codex sid:campaign-release-manager · взято 2026-01-01 00:00 · истекает $FUTURE"
check  "битый sid без пересечения → СВОБОДНО"          СВОБОДНО "$PROJ/optimize/другое"
checkx "битый sid с пересечением → ВНИМАНИЕ"           ВНИМАНИЕ "не по форме" "$PROJ/optimize/кодекс"
# Истёкшая и снятая строки не живые — и составные тоже молчат (иначе сотни старых
# строк реального файла держали бы ВНИМАНИЕ вечно).
claims "_tools/a + _tools/b · T-902 · claude · взято 2020-01-01 00:00 · истекает $PAST"
check  "составная, но истёкшая → СВОБОДНО"             СВОБОДНО "$TOOLS/b"
claims_below "optimize/{SPEC.md,AUDIT.md} · T-901 · claude · взято 2026-01-01 00:00 · истекает $FUTURE · СНЯТА 2026-01-01 01:00"
check  "составная, но снятая → СВОБОДНО"               СВОБОДНО "$PROJ/optimize/SPEC.md"
claims_below "optimize/снята · T-903 · claude · взято 2026-01-01 00:00 · истекает $FUTURE · СНЯТА 2026-01-01 01:00" \
             "optimize/истекла · T-904 · claude · взято 2020-01-01 00:00 · истекает $PAST"
check  "снятая под чужим заголовком → СВОБОДНО"        СВОБОДНО "$PROJ/optimize/снята"
check  "истёкшая под чужим заголовком → СВОБОДНО"      СВОБОДНО "$PROJ/optimize/истекла"
# Срок с хвостом (Codex пишет пояс: «… 18:15 WEST», «истекает: …») или без времени.
# Пояс сдвигает срок не больше чем на 26 ч, поэтому такая строка молчит, только
# если срок прошёл больше 26 ч назад; иначе — ВНИМАНИЕ, а не тихое «свободно».
RECENT="$(python3 -c 'from datetime import datetime,timedelta; print((datetime.now()-timedelta(hours=2)).strftime("%Y-%m-%d %H:%M"))')"
claims_below "optimize/пояс-давно · T-905 · codex sid:$SID_B · взято: 2020-01-01 00:00 WEST · истекает: 2020-01-01 02:00 WEST"
check  "срок с поясом, истёк давно → молчит"            СВОБОДНО "$PROJ/optimize/пояс-давно"
claims_below "optimize/пояс-живой · T-906 · codex sid:$SID_B · взято 2026-01-01 00:00 WEST · истекает $FUTURE WEST"
checkx "срок с поясом, не истёк → ВНИМАНИЕ"            ВНИМАНИЕ "срок не разобран" "$PROJ/optimize/другое"
claims_below "optimize/пояс-недавно · T-907 · codex · взято $RECENT UTC · истекает $RECENT UTC"
checkx "срок с поясом, истёк < 26 ч назад → ВНИМАНИЕ"  ВНИМАНИЕ "срок не разобран" "$PROJ/optimize/другое"
claims "_tools/старьё · T-908 · codex · взято 2020-01-01 · истекает 2020-01-01"
check  "живая секция: давний срок без времени → молчит" СВОБОДНО "$TOOLS/AGENTS.md"
# Codex-препасс T-156, P2: под чужим заголовком «истекает» не на своём месте
# (пропущено поле задачи) — битая заявка, громко; давняя или снятая — молчит.
# Строка вовсе без «истекает» — проза (её держит claims_below выше).
claims_below "optimize/кривая · claude sid:$SID_B · взято 2026-01-01 00:00 · истекает $FUTURE"
checkx "под заголовком: «истекает» не на месте → ВНИМАНИЕ" ВНИМАНИЕ "не разобрана" "$PROJ/optimize/другое"
claims_below "optimize/кривая · claude · взято 2020-01-01 00:00 · истекает 2020-01-01 02:00" \
             "optimize/кривая/2 · claude · СНЯТА 2026-01-01 01:00 · истекает $FUTURE"
check  "под заголовком: кривая, но давняя или снятая → молчит" СВОБОДНО "$PROJ/optimize/кривая"
# «истекает» в прозе без даты не протухнет никогда — не заявка, молчит (💭4).
claims_below "- заявка истекает после ревью, сниму сам"
check  "проза «истекает» без даты → молчит"            СВОБОДНО "$PROJ/optimize/кривая"

echo
echo "-- --sweep: протухшие по всему файлу (T-122, I-067) --"

# Фикстура повторяет устройство ЖИВОГО файла: шапка, живая секция с одной
# живой строкой, затем чужой «## »-заголовок с прозой И строками формата
# заявки под ним (по парсеру живой секции — история; именно там висели G-A4
# и T-139 три ретро подряд), строка списком `- `, уже снятая строка.
ARCHIVE="$TOOLS/.agents/runtime/claims-archive.md"
rm -f "$ARCHIVE"
{ printf '# фикстура\n\nПример формата в шапке: a/b · T · кто · взято 2020-01-01 00:00 · истекает %s\n\n## Живые заявки\n' "$PAST"
  printf '%s\n' "_tools/AGENTS.md · T-000 · claude sid:$SID_A · взято 2026-01-01 00:00 · истекает $FUTURE"
  printf '%s\n' "_tools/живая-но-протухла · T-001 · claude · взято 2020-01-01 00:00 · истекает $PAST"
  printf '\n## Автопилот такой-то · claude · 2026-09-11\n'
  printf 'Проза: области, дословная команда, статус.\n'
  printf '%s\n' "optimize/под-заголовком-1 · гейт · claude (pf-reviewer) · взято 2020-01-01 00:00 · истекает $PAST"
  printf '%s\n' "optimize/под-заголовком-2 · гейт · claude (pf-reviewer) · взято 2020-01-01 00:00 · истекает $PAST"
  printf '%s\n' "- optimize/списком · автопилот · claude · взято 2020-01-01 00:00 · истекает $PAST"
  printf '%s\n' "optimize/уже-снята · аудит · grok · взято 2020-01-01 00:00 · истекает $PAST · СНЯТО 2020-01-02 00:00"
  printf '%s\n' "optimize/живая-под-заголовком · T-002 · claude · взято 2026-01-01 00:00 · истекает $FUTURE"
} | w "$CLAIMS"
before="$(shasum -a 256 "$CLAIMS" | cut -d' ' -f1)"
out="$(bash "$SCRIPT" --sweep 2>&1)"; rc=$?
after="$(shasum -a 256 "$CLAIMS" | cut -d' ' -f1)"
n="$(printf '%s' "$out" | sed -n 's/^протухших: //p')"
if [ $rc -eq 0 ] && [ "$n" = 4 ] && [ "$before" = "$after" ] && [ ! -e "$ARCHIVE" ] \
   && [ "$(printf '%s\n' "$out" | grep -c '^ПРОТУХЛА ')" = 4 ] \
   && printf '%s' "$out" | grep -q "^ПРОТУХЛА $PAST: optimize/под-заголовком-2" \
   && printf '%s' "$out" | grep -q "^ПРОТУХЛА $PAST: - optimize/списком" \
   && ! printf '%s' "$out" | grep -q "уже-снята" \
   && ! printf '%s' "$out" | grep -q "Пример формата в шапке" \
   && printf '%s' "$out" | grep -q "^снятых руками и истёкших: 1 "; then
    pass=$((pass+1)); printf '  ✅ %-52s → протухших: 4, шапка мимо, снятых: 1\n' "--sweep: отчёт, весь файл, снятые мимо"
else
    fail=$((fail+1)); printf '  ❌ %-52s → rc=%s, протухших=%s, хеш %s\n' "--sweep: отчёт" "$rc" "$n" "$([ "$before" = "$after" ] && echo тот же || echo ИЗМЕНИЛСЯ)"
    printf '     вывод: %s\n' "$(printf '%s' "$out" | head -3)"
fi
# T-156: живая проверка читает весь файл, как свип: протухшие и снятые строки
# молчат, живая строка под чужим «## » занимает (до T-156 — СВОБОДНО, Н1 аудита 02.10).
checkx "после --sweep: своя в секции, чужие пути не мешают" СВОБОДНО "СВОБОДНО (своя)" --sid "$SID_A" "$TOOLS/AGENTS.md"
check  "живая под чужим заголовком занимает (T-156)" ЗАНЯТО "$PROJ/optimize/живая-под-заголовком"
# --sweep с областью — ВНИМАНИЕ (свип не проверка области).
checkx "--sweep с областью" ВНИМАНИЕ "не принимает область" --sweep "$TOOLS/AGENTS.md"
# --sweep --yes: 4 строки в архив с пометкой «протухла», в файле их 0,
# живые (в секции и под заголовком) и снятая — на месте, заголовки и проза целы.
out="$(bash "$SCRIPT" --sweep --yes 2>&1)"; rc=$?
after_yes="$(shasum -a 256 "$CLAIMS" | cut -d' ' -f1)"
arch_n="$(grep -c " · протухла [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\} [0-9]\{2\}:[0-9]\{2\}$" "$ARCHIVE" 2>/dev/null)"
left_n="$(grep "истекает $PAST$" "$CLAIMS" | grep -vc "Пример формата в шапке")"   # шапка остаётся
if [ $rc -eq 0 ] && [ "$arch_n" = 4 ] && [ "$left_n" = 0 ] && [ "$before" != "$after_yes" ] \
   && grep -q "^## Архив протухших$" "$ARCHIVE" \
   && grep -q "^- optimize/списком .* · протухла " "$ARCHIVE" \
   && grep -q "^## Автопилот такой-то" "$CLAIMS" && grep -q "^Проза:" "$CLAIMS" \
   && grep -q "уже-снята" "$CLAIMS" && grep -q "живая-под-заголовком" "$CLAIMS" \
   && grep -q "sid:$SID_A" "$CLAIMS" && grep -q "^Пример формата в шапке" "$CLAIMS"; then
    pass=$((pass+1)); printf '  ✅ %-52s → 4 в архив с «протухла», в файле 0\n' "--sweep --yes: перенос"
else
    fail=$((fail+1)); printf '  ❌ %-52s → rc=%s, в архиве=%s, осталось=%s\n' "--sweep --yes: перенос" "$rc" "${arch_n:-нет}" "$left_n"
    printf '     вывод: %s\n' "$(printf '%s' "$out" | head -3)"
fi
# Строка СВИП в логе событий — ровно одна на перенос (🟡-1 гейта).
if [ "$(grep -c ' · СВИП: перенесено 4 в claims-archive.md · ' "$CLAIMS_LOG" 2>/dev/null)" = 1 ]; then
    pass=$((pass+1)); printf '  ✅ %-52s → 1 строка СВИП\n' "--sweep --yes пишет СВИП в лог событий"
else fail=$((fail+1)); printf '  ❌ %-52s → строк СВИП: %s\n' "--sweep --yes пишет СВИП" "$(grep -c 'СВИП' "$CLAIMS_LOG" 2>/dev/null)"; fi
# Упавший прошлый перенос: архив записан, а claims.md — нет (строка в обоих).
# Следующий --yes НЕ дублирует её в архиве, из claims.md удаляет.
printf '%s\n' "optimize/под-заголовком-1 · гейт · claude (pf-reviewer) · взято 2020-01-01 00:00 · истекает $PAST" >> "$CLAIMS"
out="$(bash "$SCRIPT" --sweep --yes 2>&1)"; rc=$?
if [ $rc -eq 0 ] && [ "$(grep -c '^optimize/под-заголовком-1 ' "$ARCHIVE")" = 1 ] \
   && ! grep -q "^optimize/под-заголовком-1 " "$CLAIMS" && printf '%s' "$out" | grep -q "только удалены из claims.md: 1"; then
    pass=$((pass+1)); printf '  ✅ %-52s → в архиве 1, из claims.md удалена\n' "--sweep --yes: дедуп после упавшего переноса"
else fail=$((fail+1)); printf '  ❌ %-52s → rc=%s, в архиве=%s: %s\n' "дедуп" "$rc" "$(grep -c '^optimize/под-заголовком-1 ' "$ARCHIVE")" "$(printf '%s' "$out" | tail -1)"; fi
after_yes="$(shasum -a 256 "$CLAIMS" | cut -d' ' -f1)"
# Повторный --yes: переносить нечего, архив не растёт, файл не меняется.
arch_before="$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)"
out="$(bash "$SCRIPT" --sweep --yes 2>&1)"; rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q "^протухших: 0" \
   && [ "$after_yes" = "$(shasum -a 256 "$CLAIMS" | cut -d' ' -f1)" ] \
   && [ "$arch_before" = "$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)" ]; then
    pass=$((pass+1)); printf '  ✅ %-52s → протухших: 0, файлы не тронуты\n' "--sweep --yes повторно (идемпотентность)"
else fail=$((fail+1)); printf '  ❌ %-52s → rc=%s: %s\n' "--sweep --yes повторно" "$rc" "$(printf '%s' "$out" | head -2)"; fi
# Второй перенос ДОПИСЫВАЕТ в существующий архив под ту же секцию, не затирает.
claims "_tools/ещё-протухла · T-003 · claude · взято 2020-01-01 00:00 · истекает $PAST"
out="$(bash "$SCRIPT" --sweep --yes 2>&1)"; rc=$?
if [ $rc -eq 0 ] && [ "$(grep -c '^## Архив протухших$' "$ARCHIVE")" = 1 ] \
   && [ "$(grep -c ' · протухла 20' "$ARCHIVE")" = 5 ] && grep -q "под-заголовком-1" "$ARCHIVE"; then
    pass=$((pass+1)); printf '  ✅ %-52s → 5 строк, секция одна\n' "--sweep --yes: архив дописывается"
else fail=$((fail+1)); printf '  ❌ %-52s → rc=%s, секций=%s, строк=%s\n' "архив дописывается" "$rc" "$(grep -c '^## Архив протухших$' "$ARCHIVE")" "$(grep -c ' · протухла 20' "$ARCHIVE")"; fi
# Свип-отчёт в событийный лог не пишет (hygiene-sweep считает каждую строку
# проверкой); --yes пишет одну строку СВИП.
rm -f "$CLAIMS_LOG"
bash "$SCRIPT" --sweep >/dev/null 2>&1
if [ ! -e "$CLAIMS_LOG" ] || [ "$(wc -l < "$CLAIMS_LOG" | tr -d ' ')" = 0 ]; then
    pass=$((pass+1)); printf '  ✅ %-52s → лог пуст\n' "--sweep без --yes не пишет в лог событий"
else fail=$((fail+1)); printf '  ❌ %-52s → строк в логе: %s\n' "--sweep не пишет в лог" "$(wc -l < "$CLAIMS_LOG" | tr -d ' ')"; fi
# Файла заявок нет — свипу нечего сканировать, и это ВНИМАНИЕ, не «протухших: 0».
rm -f "$CLAIMS" "$ARCHIVE"
checkx "--sweep без файла заявок" ВНИМАНИЕ "файла заявок нет" --sweep

echo
echo "итого: успешно $pass, провалено $fail"
[ "$fail" -eq 0 ] || exit 1
