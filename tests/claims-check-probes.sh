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
CLAIMS="$TOOLS/.agents/runtime/claims.md"

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
    out="$(TOOLS="$TOOLS" bash "$SCRIPT" "$scope" 2>&1)"; rc=$?
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
    out="$(cd "$dir" && TOOLS="$TOOLS" bash "$SCRIPT" "$scope" 2>&1)"; rc=$?
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
# shellcheck disable=SC2097,SC2098  # ложное срабатывание: справа стоит ВНЕШНЯЯ переменная, значение то же — так и задумано
out="$(HOME="$PROJ" TOOLS="$TOOLS" bash "$SCRIPT" "$TOOLS/AGENTS.md" 2>&1)"; rc=$?
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
check "составная область (круг 1)"         ВНИМАНИЕ "$TOOLS/b"
claims "_tools/AGENTS.md·T-000·кто·взято 2026-01-01 00:00·истекает $FUTURE"
check "разделитель без пробелов (круг 1)"  ВНИМАНИЕ "$TOOLS/AGENTS.md"
claims "_tools/AGENTS.md · T-000 · кто · взято 14.08.2026 20:55 · истекает 14.08.2026 20:55"
check "дата в чужом формате (круг 2)"      ВНИМАНИЕ "$TOOLS/AGENTS.md"
{ printf '# фикстура\n\n## Текущие держания\n\n_tools/AGENTS.md · T-000 · кто · взято 2026-01-01 00:00 · истекает %s\n' "$FUTURE"; } | w "$CLAIMS"
check "переименованная секция (круг 2)"    ВНИМАНИЕ "$TOOLS/AGENTS.md"
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
# 💭 закрывающего гейта: похожий заголовок — не живая секция; календарно
# невозможная дата — не живой срок; пустая область — не «занято на всё».
{ printf '# ф\n\n## Живые заявки (архив)\n\n_tools/AGENTS.md · T-000 · кто · взято 2026-01-01 00:00 · истекает %s\n' "$FUTURE"; } | w "$CLAIMS"
check "секция «## Живые заявки (архив)» — не живая" ВНИМАНИЕ "$TOOLS/AGENTS.md"
claims "_tools/AGENTS.md · T-000 · кто · взято 2026-01-01 00:00 · истекает 2026-13-40 25:61"
check "календарно невозможный срок"        ВНИМАНИЕ "$TOOLS/AGENTS.md"
claims " · T-000 · кто · взято 2026-01-01 00:00 · истекает $FUTURE"
check "пустая область в строке заявки"      ВНИМАНИЕ "$PROJ/optimize/SPEC.md"
claims "просто строка прозы внутри секции"
check "проза внутри секции"                ВНИМАНИЕ "$TOOLS/AGENTS.md"
{ printf '# ф\n\n## Живые заявки\n\n## Архив\n\n_tools/AGENTS.md · T-000 · кто · взято 2026-01-01 00:00 · истекает %s\n' "$FUTURE"; } | w "$CLAIMS"
check "живая строка ниже, под ## Архив"    СВОБОДНО "$TOOLS/AGENTS.md"
claims "_tools/AGENTS.md · T-000 · кто · взято 2026-01-01 00:00 · истекает $FUTURE"
chmod 000 "$CLAIMS"
check "нечитаемый файл при живой заявке"   ВНИМАНИЕ "$TOOLS/AGENTS.md"
chmod 644 "$CLAIMS"

echo
echo "-- смешанное состояние и пустой ввод --"
claims "битая строка" "_tools/AGENTS.md · T-000 · кто · взято 2026-01-01 00:00 · истекает $FUTURE"
# shellcheck disable=SC2097,SC2098  # ложное срабатывание: справа стоит ВНЕШНЯЯ переменная, значение то же — так и задумано
out="$(TOOLS="$TOOLS" bash "$SCRIPT" "$TOOLS/AGENTS.md" 2>&1)"; rc=$?
if [ $rc -eq 1 ] && printf '%s' "$out" | grep -q "ЗАНЯТО" && printf '%s' "$out" | grep -q "ВНИМАНИЕ"; then
    pass=$((pass+1)); printf '  ✅ %-52s → ЗАНЯТО (rc=1) + ВНИМАНИЕ напечатано\n' "живая заявка + мусорная строка"
else
    fail=$((fail+1)); printf '  ❌ %-52s → rc=%s, вывод: %s\n' "живая заявка + мусорная строка" "$rc" "$out"
fi
check "область из одних пробелов"          ВНИМАНИЕ "   "
# shellcheck disable=SC2097,SC2098  # ложное срабатывание: справа стоит ВНЕШНЯЯ переменная, значение то же — так и задумано
out="$(TOOLS="$TOOLS" bash "$SCRIPT" 2>&1)"; rc=$?
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
# shellcheck disable=SC2097,SC2098  # ложное срабатывание: справа стоит ВНЕШНЯЯ переменная, значение то же — так и задумано
out="$(TOOLS="$WORK/нет-такого" bash "$SCRIPT" "$TOOLS/AGENTS.md" 2>&1)"; rc=$?
if [ $rc -eq 2 ]; then pass=$((pass+1)); printf '  ✅ %-52s → ВНИМАНИЕ (rc=2)\n' "TOOLS мимо (каталога нет)"
else fail=$((fail+1)); printf '  ❌ %-52s → rc=%s: %s\n' "TOOLS мимо" "$rc" "$out"; fi
ln -s "$WORK/в-никуда" "$CLAIMS"
# shellcheck disable=SC2097,SC2098  # ложное срабатывание: справа стоит ВНЕШНЯЯ переменная, значение то же — так и задумано
out="$(TOOLS="$TOOLS" bash "$SCRIPT" "$TOOLS/AGENTS.md" 2>&1)"; rc=$?
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
echo "итого: успешно $pass, провалено $fail"
[ "$fail" -eq 0 ] || exit 1
