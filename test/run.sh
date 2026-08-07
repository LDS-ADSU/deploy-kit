#!/usr/bin/env bash
#
# Стенд для deploy/*.sh. Подменяет sudo/systemctl/caddy/curl стабами (deploy/test/stub) и гоняет
# сценарии на временном DEPLOY_DIR. Инфраструктура не нужна — запускается где угодно за ~2 минуты.
#
#   deploy/test/run.sh
#
# Зачем: эти скрипты переключают ПРОД-трафик, и за один день в них нашлось два бага, доехавших
# до прода (заякоренная на порядок ключей проверка readiness и грep по несуществующей строке
# в выводе javaToolchains). Проверяются наблюдаемые эффекты — какой цвет перезапущен, куда
# смотрит апстрим, что лежит в RELEASE, — а не текст сообщений.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO:-$(cd "$HERE/../.." && pwd)}"
PASS=0; FAIL=0

setup() {                       # setup <активный-цвет>
    WORK="$(mktemp -d)"
    export DEPLOY_DIR="$WORK" STUB_LOG="$WORK/calls.log" STUB_STATE="$WORK"
    export CADDY_UPSTREAM="$WORK/caddy/active-upstream.caddy" CADDYFILE="$WORK/Caddyfile"
    export PATH="$HERE/stub:$PATH"
    mkdir -p "$WORK/caddy" "$WORK/blue" "$WORK/green" "$WORK/releases"
    : > "$STUB_LOG"; echo 0 > "$WORK/nrestarts"; touch "$CADDYFILE"
    local p; p=2333; [ "$1" = green ] && p=2343
    printf 'to 127.0.0.1:%s\n' "$p" > "$CADDY_UPSTREAM"
    printf '%s\n' "$1" > "$WORK/active"
    echo "old-jar-blue"  > "$WORK/blue/team.jar";  echo old-blue  > "$WORK/blue/RELEASE"
    echo "old-jar-green" > "$WORK/green/team.jar"; echo old-green > "$WORK/green/RELEASE"
    echo "new-jar" > "$WORK/new.jar"
    unset STUB_STATUS_FIRST STUB_READY STUB_INFO_COMMIT STUB_PROBE_CODE STUB_ADMIN \
          STUB_ADMIN_PORT STUB_CADDY_RELOAD_FAIL STUB_RESTART_FAIL \
          ALLOW_SAME_RELEASE SKIP_RELEASE_CHECK
    export HEALTH_TIMEOUT=6 RESTORE_TIMEOUT=6
}

check() {                       # check <описание> <ожидание> <факт>
    if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s: ждали [%s], получили [%s]\n' "$1" "$2" "$3"; fi
}
upstream_port() { sed -n 's#.*:\([0-9]*\)#\1#p' "$CADDY_UPSTREAM"; }
restarts_of()   { grep -c "systemctl restart adsu-team@$1" "$STUB_LOG" 2>/dev/null | tr -d ' '; }
deploy()        { bash "$REPO/deploy/deploy.sh" "$DEPLOY_DIR/new.jar" "${1:-abc123456789}" 2>&1; }

echo "1. штатный деплой blue → green"
setup blue
export STUB_READY="blue green" STUB_INFO_COMMIT=abc123456789ff STUB_PROBE_CODE=407 STUB_ADMIN_PORT=2343
out="$(deploy)"; rc=$?
check "код возврата 0"                 "0"    "$rc"
check "апстрим Caddy → green"          "2343" "$(upstream_port)"
check "active обновлён"                "green" "$(cat "$DEPLOY_DIR/active")"
check "RELEASE у green записан"        "abc123456789" "$(cat "$DEPLOY_DIR/green/RELEASE")"
check "jar доставлен в green"          "new-jar" "$(cat "$DEPLOY_DIR/green/team.jar")"
check "blue НЕ перезапускался"         "0"    "$(restarts_of blue)"
check "green перезапущен один раз"     "1"    "$(restarts_of green)"
check "сборка попала в архив"          "new-jar" "$(cat "$DEPLOY_DIR/releases/abc123456789.jar")"
check "team.jar.prev убран"            "нет"  "$([ -f "$DEPLOY_DIR/green/team.jar.prev" ] && echo есть || echo нет)"
check "ни одного !! на успешном пути"  "нет"  "$(printf '%s' "$out" | grep -q '^!!' && echo да || echo нет)"

echo "2. новая сборка не поднимается → трафик не трогаем, резерв восстановлен"
setup blue
export STUB_READY="blue" STUB_INFO_COMMIT=abc123456789ff STUB_PROBE_CODE=407 STUB_ADMIN_PORT=2343
out="$(deploy)"; rc=$?
check "код возврата 1"                 "1"    "$rc"
check "апстрим остался на blue"        "2333" "$(upstream_port)"
check "active не тронут"               "blue" "$(cat "$DEPLOY_DIR/active")"
check "в green возвращён старый jar"   "old-jar-green" "$(cat "$DEPLOY_DIR/green/team.jar")"
check "RELEASE green не изменён"       "old-green" "$(cat "$DEPLOY_DIR/green/RELEASE")"
check "напечатана диагностика"         "да"   "$(printf '%s' "$out" | grep -q 'диагностика green' && echo да || echo нет)"

echo "3. active врёт (говорит blue, Caddy шлёт в green)"
setup green
printf 'blue\n' > "$DEPLOY_DIR/active"
export STUB_READY="blue green" STUB_INFO_COMMIT=abc123456789ff STUB_PROBE_CODE=407 STUB_ADMIN_PORT=2333
out="$(deploy)"; rc=$?
check "код возврата 0"                 "0"    "$rc"
check "предупреждение о расхождении"   "да"   "$(printf '%s' "$out" | grep -q 'ВНИМАНИЕ.*говорит' && echo да || echo нет)"
check "это предупреждение, а не отказ" "нет"  "$(printf '%s' "$out" | grep -q '^!!' && echo да || echo нет)"
check "катили в blue (реальный резерв)" "new-jar" "$(cat "$DEPLOY_DIR/blue/team.jar")"
check "green (под трафиком) не тронут" "old-jar-green" "$(cat "$DEPLOY_DIR/green/team.jar")"
check "green НЕ перезапускался"        "0"    "$(restarts_of green)"

echo "4. апстрим Caddy нечитаем"
setup blue
rm -f "$CADDY_UPSTREAM"
export STUB_READY="blue green"
out="$(deploy)"; rc=$?
check "деплой остановлен"              "1"    "$rc"
check "ничего не перезапускали"        "0"    "$(grep -c 'systemctl restart' "$STUB_LOG" | tr -d ' ')"

echo "5. раскатка релиза, который уже под трафиком"
setup blue
printf 'abc123456789\n' > "$DEPLOY_DIR/blue/RELEASE"
export STUB_READY="blue green"
out="$(deploy)"; rc=$?
check "отказ"                          "1"    "$rc"
check "green не тронут"                "old-jar-green" "$(cat "$DEPLOY_DIR/green/team.jar")"
export ALLOW_SAME_RELEASE=1 STUB_INFO_COMMIT=abc123456789ff STUB_PROBE_CODE=407 STUB_ADMIN_PORT=2343
out="$(deploy)"; rc=$?
check "ALLOW_SAME_RELEASE=1 пропускает" "0"   "$rc"

echo "6. /actuator/info отдаёт чужой коммит"
setup blue
export STUB_READY="blue green" STUB_INFO_COMMIT=999999999999 STUB_PROBE_CODE=407 STUB_ADMIN_PORT=2343
out="$(deploy)"; rc=$?
check "трафик не переключён"           "1"    "$rc"
check "апстрим остался на blue"        "2333" "$(upstream_port)"

echo "7. приложение отвечает 500 на app-порту"
setup blue
export STUB_READY="blue green" STUB_INFO_COMMIT=abc123456789ff STUB_PROBE_CODE=500 STUB_ADMIN_PORT=2343
out="$(deploy)"; rc=$?
check "трафик не переключён"           "1"    "$rc"
check "апстрим остался на blue"        "2333" "$(upstream_port)"

echo "8. sites/api.caddy не импортирует апстрим"
setup blue
export STUB_READY="blue green" STUB_INFO_COMMIT=abc123456789ff STUB_PROBE_CODE=407 STUB_ADMIN_PORT=2333
out="$(deploy)"; rc=$?
check "отказ"                          "1"    "$rc"
check "апстрим возвращён на blue"      "2333" "$(upstream_port)"

echo "9. rollback при живом резерве"
setup green
export STUB_READY="blue green"
out="$(bash "$REPO/deploy/rollback.sh" 2>&1)"; rc=$?
check "код возврата 0"                 "0"    "$rc"
check "апстрим → blue"                 "2333" "$(upstream_port)"
check "живой резерв НЕ перезапускали"  "0"    "$(grep -c 'systemctl restart' "$STUB_LOG" | tr -d ' ')"
check "active обновлён"                "blue" "$(cat "$DEPLOY_DIR/active")"

echo "10. rollback при лежащем резерве"
setup green
export STUB_READY="green"
out="$(bash "$REPO/deploy/rollback.sh" 2>&1)"; rc=$?
check "откат прерван"                  "1"    "$rc"
check "попытка поднять была"           "1"    "$(restarts_of blue)"
check "апстрим остался на green"       "2343" "$(upstream_port)"

echo "11. release.sh"
setup blue
cp "$DEPLOY_DIR/new.jar" "$DEPLOY_DIR/releases/old111111111.jar"
export STUB_READY="blue green" STUB_INFO_COMMIT=old111111111ff STUB_PROBE_CODE=407 STUB_ADMIN_PORT=2343
out="$(bash "$REPO/deploy/release.sh" --list 2>&1)"
check "--list показывает архив"        "да" "$(printf '%s' "$out" | grep -q old111111111 && echo да || echo нет)"
out="$(bash "$REPO/deploy/release.sh" nosuch 2>&1)"; rc=$?
check "несуществующий релиз → отказ"   "1"  "$rc"
out="$(bash "$REPO/deploy/release.sh" old111111111 2>&1)"; rc=$?
check "выкатка из архива прошла"       "0"    "$rc"
check "апстрим → green"                "2343" "$(upstream_port)"
check "архивный jar не потерян"        "new-jar" "$(cat "$DEPLOY_DIR/releases/old111111111.jar")"

echo "12. rollback, caddy reload падает"
setup green
export STUB_READY="blue green" STUB_CADDY_RELOAD_FAIL=1
out="$(bash "$REPO/deploy/rollback.sh" 2>&1)"; rc=$?
check "откат провален"                 "1"    "$rc"
check "апстрим ВЕРНУЛСЯ на green"      "2343" "$(upstream_port)"
check "active не переписан"            "green" "$(cat "$DEPLOY_DIR/active")"

echo "13. deploy, systemctl restart падает"
setup blue
export STUB_READY="blue green" STUB_RESTART_FAIL=1
out="$(deploy)"; rc=$?
check "деплой провален"                "1"    "$rc"
check "в green возвращён старый jar"   "old-jar-green" "$(cat "$DEPLOY_DIR/green/team.jar")"
check "апстрим остался на blue"        "2333" "$(upstream_port)"

echo "14. апстрим с комментарием выше директивы to"
setup blue
printf '# был 127.0.0.1:2343 до инцидента\nto 127.0.0.1:2333\n' > "$CADDY_UPSTREAM"
export STUB_READY="blue green" STUB_INFO_COMMIT=abc123456789ff STUB_PROBE_CODE=407 STUB_ADMIN_PORT=2343
out="$(deploy)"; rc=$?
check "цвет определён верно (blue)"    "0"    "$rc"
check "катили в green"                 "new-jar" "$(cat "$DEPLOY_DIR/green/team.jar")"

echo "15. RELEASE записан до переключения трафика"
setup blue
export STUB_READY="blue green" STUB_INFO_COMMIT=abc123456789ff STUB_PROBE_CODE=407 STUB_ADMIN_PORT=2333
out="$(deploy)"; rc=$?
check "отказ на проверке конфига"      "1"    "$rc"
check "RELEASE green уже записан"      "abc123456789" "$(cat "$DEPLOY_DIR/green/RELEASE")"

echo "16. readiness со status ПЕРВЫМ ключом (регрессия fde2b3a)"
setup blue
export STUB_READY="blue green" STUB_STATUS_FIRST=1 STUB_INFO_COMMIT=abc123456789ff STUB_PROBE_CODE=407 STUB_ADMIN_PORT=2343
out="$(deploy)"; rc=$?
check "деплой прошёл"                  "0"    "$rc"
check "апстрим → green"                "2343" "$(upstream_port)"

echo
printf 'Итого: \033[32m%d ok\033[0m, \033[31m%d fail\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
