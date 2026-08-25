#!/usr/bin/env bash
#
# Deploys a SPECIFIC build out of the archive (deploy/releases/<release-id>.jar) through the ordinary
# blue-green cycle in deploy.sh.
#
# Why this exists alongside rollback.sh: that one can only switch to the other colour, which is exactly
# one step back. After two deploys in a row both colours carry new code, and the only way back to a
# particular version is from here.
#
# Usage:
# deploy/release.sh --list          # what the archive holds and what each colour runs
# deploy/release.sh <release-id>    # deploy that build to standby and switch traffic
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"       # supplies DEPLOY_DIR from the profile and checks the profile is complete
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
