#!/usr/bin/env bash
#
# Общие примитивы blue-green для deploy.sh / rollback.sh / release.sh.
# Подключается через `source`, самостоятельного запуска не предполагает.
#
# Здесь собрано ровно то, что раньше дублировалось между deploy.sh и rollback.sh и в двух копиях
# разъезжалось (разные бюджеты health-check, разные эндпоинты, разный порядок записи состояния).

# The service profile is the only thing that differs between the five backends. It is a
# sourced shell file of `: "${KEY:=value}"` assignments, so the ENVIRONMENT always wins over
# the profile — deploy.yml keeps passing DEPLOY_DIR and the test harness keeps pointing the
# whole thing at a temporary directory, and neither has to learn that profiles exist.
# Рядом с установленной копией скриптов лежит service.conf (см. install_bin в deploy.sh),
# поэтому /opt/backend/<сервис>/bin/rollback.sh запускается дежурным без единой переменной
# окружения. Условие через `if`, а не `[ ] && [ ] && VAR=`: последнее под set -e уронило бы
# скрипт, когда первая проверка ложна.
if [ -z "${SERVICE_PROFILE:-}" ]; then
    _kit_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -r "$_kit_dir/service.conf" ]; then SERVICE_PROFILE="$_kit_dir/service.conf"; fi
    unset _kit_dir
fi
: "${SERVICE_PROFILE:?не задан SERVICE_PROFILE — укажите путь к service.conf сервиса}"
[ -r "$SERVICE_PROFILE" ] || { echo "!! профиль $SERVICE_PROFILE не читается" >&2; exit 1; }
# Приводим к абсолютному: install_bin копирует профиль на хост, а deploy.sh мог быть запущен
# из любого каталога — относительный путь после смены cwd указывал бы в никуда.
SERVICE_PROFILE="$(cd "$(dirname "$SERVICE_PROFILE")" && pwd)/$(basename "$SERVICE_PROFILE")"
# shellcheck source=/dev/null
. "$SERVICE_PROFILE"

# An incomplete profile must fail here, not halfway through a deploy: an empty DEPLOY_DIR would
# root every path below at /, and an empty SERVICE_UNIT would hand systemctl the literal unit
# `@green` — both discovered only once something had already been moved or restarted.
for _key in SERVICE_UNIT DEPLOY_DIR JAR_NAME APP_PORT_BLUE APP_PORT_GREEN; do
    [ -n "${!_key:-}" ] || { echo "!! в профиле $SERVICE_PROFILE не задан $_key" >&2; exit 1; }
done
unset _key

# A separate management port is optional: status-monitor serves Actuator on the application port
# itself, so its profile omits MGMT_PORT_* and both resolve to the same socket.
: "${MGMT_PORT_BLUE:=$APP_PORT_BLUE}"
: "${MGMT_PORT_GREEN:=$APP_PORT_GREEN}"
: "${HEALTH_TIMEOUT:=600}"

CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
CADDY_UPSTREAM="${CADDY_UPSTREAM:-$DEPLOY_DIR/caddy/active-upstream.caddy}"
CADDY_ADMIN="${CADDY_ADMIN:-http://127.0.0.1:2019}"
ACTIVE_FILE="$DEPLOY_DIR/active"
LOCK_FILE="${LOCK_FILE:-$DEPLOY_DIR/.switch.lock}"

app_port()  { case "$1" in blue) echo "$APP_PORT_BLUE";;  green) echo "$APP_PORT_GREEN";;  esac; }
mgmt_port() { case "$1" in blue) echo "$MGMT_PORT_BLUE";; green) echo "$MGMT_PORT_GREEN";; esac; }
other()     { case "$1" in blue) echo green;; green) echo blue;; esac; }

release_of() { cat "$DEPLOY_DIR/$1/RELEASE" 2>/dev/null || echo '?'; }

# Единый словарь сообщений. Префикс сразу говорит, чем кончится дело, — это важно при разборе
# инцидента: `grep '!!'` в логе Actions должен давать ТОЛЬКО то, из-за чего работа прекратилась,
# а не вперемешку с безобидными замечаниями.
#   step — очередной шаг, всё идёт по плану
#   warn — работа продолжается, но человеку стоит об этом знать
#   die  — отказ, дальше скрипт не идёт
# Продолжение любой из них — cont (отступ), чтобы фраза не рвалась между двумя echo.
# Голос везде один: первое лицо единственного числа («раскатываю», «жду», «возвращаю»),
# к читателю — на «вы».
step() { echo ">> $*"; }
warn() { echo ">> ВНИМАНИЕ: $*"; }
die()  { echo "!! $*" >&2; }
cont() { echo "   $*"; }

# Взаимоисключение деплоя и ручного отката: оба переписывают апстрим Caddy и оба зовут reload.
# `concurrency` в deploy.yml сериализует только прогоны Actions и про дежурного, запустившего
# rollback.sh руками посреди деплоя, ничего не знает.
acquire_switch_lock() {
    if ! command -v flock >/dev/null 2>&1; then
        warn "flock не найден: одновременный запуск деплоя и отката ничем не разведён"
        return 0
    fi
    # Файл заводим групповым и открываем на ЧТЕНИЕ: flock прав на запись не требует, а лок,
    # созданный под одним пользователем с umask 022, иначе заблокировал бы всех остальных.
    ( umask 0002; : >> "$LOCK_FILE" ) 2>/dev/null || true
    chmod 0664 "$LOCK_FILE" 2>/dev/null || true
    exec 9<"$LOCK_FILE" || { die "не удалось открыть файл блокировки $LOCK_FILE"; exit 1; }
    flock -n 9 || { die "деплой или откат уже выполняется — прерываю (блокировка $LOCK_FILE)"; exit 1; }
}

# Активный цвет — тот, на который РЕАЛЬНО смотрит Caddy. Файл `active` справочный: он пишется
# уже после `caddy reload`, поэтому отстаёт при сбое записи и при ручной правке апстрима в
# инциденте. Ошибка здесь — самая дорогая из возможных: рестарт активного цвета означает
# простой на всё время старта JVM, ровно посреди «безопасного» blue-green.
detect_active() {
    local port color noted
    # Порт якорим на КОНЕЦ строки и берём только незакомментированные директивы `to`,
    # иначе комментарий или порт вида 23331 дали бы неверный цвет. Ширина 2–5 цифр, а не ровно
    # четыре: порты сервисов кита идут от 2050 до 9011, и жёсткая четвёрка молча отрезала бы
    # любой пятизначный — деплой встал бы на «не могу определить активный цвет».
    port="$(grep -E '^[[:space:]]*to[[:space:]]' "$CADDY_UPSTREAM" 2>/dev/null \
        | sed -n 's/.*127\.0\.0\.1:\([0-9]\{2,5\}\)[[:space:]]*$/\1/p' | head -n1)"
    case "$port" in
        "$APP_PORT_BLUE")  color=blue ;;
        "$APP_PORT_GREEN") color=green ;;
        *)
            die "не могу определить активный цвет: в $CADDY_UPSTREAM нет строки вида" \
                "'to 127.0.0.1:$APP_PORT_BLUE' (найдено: '${port:-ничего}')"
            cont "Это единственный достоверный признак того, куда сейчас идёт трафик," >&2
            cont "поэтому дальше не иду. Почините файл и повторите запуск." >&2
            return 1
            ;;
    esac
    noted="$(cat "$ACTIVE_FILE" 2>/dev/null || true)"
    if [ -n "$noted" ] && [ "$noted" != "$color" ]; then
        warn "файл $ACTIVE_FILE говорит '$noted', а Caddy шлёт трафик в '$color'." >&2
        cont "Верю Caddy: файл справочный и мог отстать. Продолжаю с '$color'." >&2
    fi
    echo "$color"
}

# Готовность цвета проверяем по ГРУППЕ readiness (readinessState + r2dbc), а не по агрегату
# /actuator/health: в агрегат входят redis и diskSpace, из-за которых деплой полностью
# работоспособного инстанса упирается в недоступный кэш.
#
# Основной гейт — HTTP-код: Actuator отдаёт 200 на UP и 503 на DOWN/OUT_OF_SERVICE.
# Тело проверяем ДОПОЛНИТЕЛЬНО и только на отсутствие не-UP статусов — чтобы отсечь UNKNOWN,
# который тоже маппится в 200.
#
# Никаких предположений о ПОРЯДКЕ ключей: группа readiness наследует show-details: always и
# реально отвечает `{"components":{...},"status":"UP"}`, то есть components ПЕРВЫМ ключом.
# Якорь на `^{"status":"UP"` из-за этого проваливал проверку у полностью здорового инстанса —
# деплой fde2b3a простоял 600с и откатился, хотя приложение работало (порядок ключей в JSON
# не гарантирован ничем, и полагаться на него нельзя).
is_healthy() {
    local url resp code body
    url="http://127.0.0.1:$(mgmt_port "$1")/actuator/health/readiness"
    # Код дописываем в хвост тела без разделителя и отрезаем позиционно: формат -w без
    # escape-последовательностей не зависит от того, как их раскрывает конкретный curl.
    resp="$(curl -s --max-time 5 -w '%{http_code}' "$url" 2>/dev/null)" || return 1
    code="${resp: -3}"
    body="${resp%???}"
    [ "$code" = "200" ] || return 1
    case "$body" in
        *'"status":"DOWN"'*|*'"status":"OUT_OF_SERVICE"'*|*'"status":"UNKNOWN"'*) return 1 ;;
    esac
    return 0
}

# Ждём готовности до дедлайна, но выходим раньше, если systemd успел перезапустить юнит:
# Restart=on-failure означает, что упавшая на старте сборка будет подниматься снова и снова,
# и досиживать бюджет до конца бессмысленно.
wait_healthy() {
    local color="$1" timeout="${2:-$HEALTH_TIMEOUT}" unit deadline nr0 nr
    unit="$SERVICE_UNIT@$color"
    nr0="$(systemctl show -p NRestarts --value "$unit" 2>/dev/null || true)"
    deadline=$(( $(date +%s) + timeout ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if is_healthy "$color"; then return 0; fi
        # Одиночный авто-рестарт переживаем: приложение могло упасть на транзиентной
        # недоступности БД и подняться со второй попытки. Два и больше — это цикл.
        # Значения проверяем на числовость: нечисловая строка в $(( )) под set -u убила бы скрипт.
        nr="$(systemctl show -p NRestarts --value "$unit" 2>/dev/null || true)"
        case "$nr0$nr" in *[!0-9]*|'') nr='' ;; esac
        if [ -n "$nr" ] && [ "$((nr - nr0))" -ge 2 ]; then
            die "$unit падал и перезапускался systemd $((nr - nr0)) раз: дальше ждать нечего"
            return 1
        fi
        sleep 2
    done
    die "$color не вышел в готовность за ${timeout}с"
    return 1
}

# Диагностика цвета, не прошедшего гейт готовности. Сам факт «не поднялся за N секунд» не
# различает два совершенно разных случая: приложение не слушает вовсе — или слушает и
# осознанно отвечает DOWN (например, недоступна БД в группе readiness). Без этого разбор
# требует человека с ssh на прод-хосте, что превращает любой красный деплой в переписку.
# Всё best-effort: диагностика не имеет права влиять на код возврата.
diagnose_color() {
    local color="$1" mport aport
    mport="$(mgmt_port "$color")"; aport="$(app_port "$color")"
    echo "-- диагностика $color ------------------------------------------------------"
    local url
    for url in "http://127.0.0.1:$mport/actuator/health/readiness" \
               "http://127.0.0.1:$mport/actuator/health" \
               "http://127.0.0.1:$mport/actuator/info"; do
        echo "   $url"
        echo "     код: $(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || echo 'нет соединения')"
        echo "     тело: $(curl -s --max-time 5 "$url" 2>/dev/null | head -c 600 || true)"
    done
    # Смоук-путь есть не у каждого сервиса: без него по app-порту стучаться некуда, и строка
    # просто не печатается — лучше, чем показывать 404 на выдуманном пути.
    if [ -n "${SMOKE_PATH:-}" ]; then
        echo "   app-порт $aport: код $(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
            "http://127.0.0.1:$aport$SMOKE_PATH" 2>/dev/null || echo 'нет соединения')"
    fi
    echo "   systemctl status $SERVICE_UNIT@$color:"
    systemctl status "$SERVICE_UNIT@$color" --no-pager -n 30 2>&1 | sed 's/^/     /' || true
    echo "-------------------------------------------------------------------------"
}

# Апстрим пишем через временный файл: Caddy может читать его в момент правки, а частично
# записанный `to 127.0.0.1:23` уронит reload.
switch_upstream() {
    printf 'to 127.0.0.1:%s\n' "$(app_port "$1")" > "$CADDY_UPSTREAM.tmp"
    chmod 0644 "$CADDY_UPSTREAM.tmp"
    mv -f "$CADDY_UPSTREAM.tmp" "$CADDY_UPSTREAM"
}

reload_caddy() { caddy reload --config "$CADDYFILE" --adapter caddyfile; }

# Переключение трафика ВСЕГДА через этот примитив: апстрим-файл — источник правды об активном
# цвете (см. detect_active), поэтому он не должен переживать неудавшийся reload ни на секунду.
# Иначе следующий деплой посчитает боевым не тот цвет и перезапустит его под нагрузкой.
# apply_upstream <новый-цвет> <прежний-цвет>
apply_upstream() {
    switch_upstream "$1"
    if ! reload_caddy; then
        die "caddy reload не прошёл — возвращаю апстрим на $2"
        switch_upstream "$2"
        reload_caddy || true
        return 1
    fi
}

# `active` — справочный файл (источник правды см. detect_active), поэтому неудачная запись
# не должна ронять скрипт: трафик к этому моменту уже переключён.
record_active() {
    printf '%s\n' "$1" > "$ACTIVE_FILE" 2>/dev/null \
        || warn "не удалось обновить $ACTIVE_FILE. Файл справочный, трафик уже на $1"
}
