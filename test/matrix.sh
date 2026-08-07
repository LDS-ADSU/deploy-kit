#!/usr/bin/env bash
#
# Прогон стенда по ВСЕМ профилям сразу — то, ради чего кит и заводился: одна реализация
# blue-green, проверенная на всех пяти сервисах, вместо пяти копий, проверенных на одном.
#
#   test/matrix.sh
#
# Печатает по строке на профиль. Полный вывод — только у упавшего, иначе пять прогонов
# превращают лог в простыню, в которой единственная красная строка теряется.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc_all=0
for prof in "$HERE"/profiles/*.conf; do
    name="$(basename "$prof" .conf)"
    out="$(PROFILE="$prof" bash "$HERE/run.sh" 2>&1)"; rc=$?
    printf '%-16s %s\n' "$name" "$(printf '%s' "$out" | tail -1)"
    if [ "$rc" -ne 0 ]; then
        printf '%s\n' "$out" | sed 's/^/    /'
        rc_all=1
    fi
done
exit "$rc_all"
