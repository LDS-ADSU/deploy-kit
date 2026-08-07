#!/usr/bin/env bash
#
# Выкатка КОНКРЕТНОЙ сборки из архива (deploy/releases/<release-id>.jar) через обычный
# blue-green цикл deploy.sh.
#
# Зачем, если есть rollback.sh: тот умеет только «переключиться на другой цвет», то есть ровно на
# один шаг назад. После двух деплоёв подряд оба цвета уже несут новый код, и вернуться на нужную
# версию можно только отсюда.
#
# Использование:
#   deploy/release.sh --list          # что есть в архиве и что сейчас на цветах
#   deploy/release.sh <release-id>    # выкатить эту сборку в standby и переключить трафик
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"       # даёт DEPLOY_DIR из профиля и проверяет, что профиль полон
RELEASES_DIR="$DEPLOY_DIR/releases"

list_releases() {
    echo "Архив сборок $RELEASES_DIR (свежие сверху):"
    ls -1t "$RELEASES_DIR"/*.jar 2>/dev/null | sed 's#.*/##; s#\.jar$##; s#^#  #' || echo "  (пусто)"
    echo "Сейчас на цветах: blue=$(cat "$DEPLOY_DIR/blue/RELEASE" 2>/dev/null || echo '?')," \
         "green=$(cat "$DEPLOY_DIR/green/RELEASE" 2>/dev/null || echo '?')"
}

case "${1:-}" in
    --list) list_releases; exit 0 ;;
    "")     echo "usage: release.sh <release-id> | --list"; list_releases; exit 1 ;;
esac

JAR="$RELEASES_DIR/$1.jar"
if [ ! -f "$JAR" ]; then
    echo "!! сборки '$1' в архиве нет"
    list_releases
    exit 1
fi

exec "$HERE/deploy.sh" "$JAR" "$1"
