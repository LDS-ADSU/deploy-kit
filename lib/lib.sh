#!/usr/bin/env bash
#
# The blue-green primitives shared by deploy.sh, rollback.sh and release.sh.
# Sourced, never run on its own.
#
# Everything here has to live in one place: kept as two copies in deploy.sh and rollback.sh, these
# drift — different health-check budgets, different endpoints, a different order of writing state.

# The service profile is the only thing that differs between the five backends. It is a
# sourced shell file of `: "${KEY:=value}"` assignments, so the ENVIRONMENT always wins over
# the profile — deploy.yml keeps passing DEPLOY_DIR and the test harness keeps pointing the
# whole thing at a temporary directory, and neither has to learn that profiles exist.
# service.conf sits next to the installed copy of the scripts (see install_bin in deploy.sh), so
# /opt/backend/<service>/bin/rollback.sh runs for on-call with no environment variables at all.
# Written as an `if` rather than `[ ] && [ ] && VAR=`: the latter kills the script under set -e when
# the first test is false.
if [ -z "${SERVICE_PROFILE:-}" ]; then
    _kit_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -r "$_kit_dir/service.conf" ]; then SERVICE_PROFILE="$_kit_dir/service.conf"; fi
    unset _kit_dir
fi
: "${SERVICE_PROFILE:?не задан SERVICE_PROFILE — укажите путь к service.conf сервиса}"
[ -r "$SERVICE_PROFILE" ] || { echo "!! профиль $SERVICE_PROFILE не читается" >&2; exit 1; }
# Made absolute: install_bin copies the profile to the host, and deploy.sh may have been started from
# any directory — a relative path would point nowhere once the working directory changes.
SERVICE_PROFILE="$(cd "$(dirname "$SERVICE_PROFILE")" && pwd)/$(basename "$SERVICE_PROFILE")"
# Linted against the example profile rather than /dev/null: otherwise shellcheck reports SERVICE_UNIT,
# JAR_NAME and the ports as unassigned (SC2154) in all four scripts at once.
# shellcheck source=../service.conf.example
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

# One vocabulary for messages. The prefix says up front how the run ends, which is what matters while
# triaging an incident: `grep '!!'` over an Actions log must return ONLY what stopped the work, not
# harmless remarks mixed in with it.
# step — another step, going to plan
# warn — the run continues, but someone should know
# die  — a refusal; the script goes no further
# A continuation of any of them is cont, indented, so a sentence does not break across two echoes.
# The messages stay Russian and keep one voice: first person singular for what the script does, and
# the formal second person for the reader.
step() { echo ">> $*"; }
warn() { echo ">> ВНИМАНИЕ: $*"; }
die()  { echo "!! $*" >&2; }
cont() { echo "   $*"; }

# Mutual exclusion between a deploy and a manual rollback: both rewrite the Caddy upstream and both
# call reload. `concurrency` in deploy.yml serialises only Actions runs and knows nothing about
# on-call starting rollback.sh by hand in the middle of a deploy.
acquire_switch_lock() {
    if ! command -v flock >/dev/null 2>&1; then
        warn "flock не найден: одновременный запуск деплоя и отката ничем не разведён"
        return 0
    fi
    # The file is group-writable and opened for READING: flock needs no write permission, and a lock
    # created by one user under umask 022 would otherwise shut everyone else out.
    #
    # Failing to create it means the runner's user cannot write to $DEPLOY_DIR itself. That is a
    # permissions defect on the host, not a reason to stop the rollout: without the lock the only thing
    # lost is exclusion against a MANUAL rollback — parallel deploys are already serialised by
    # `concurrency` in the workflow — whereas refusing here means the service cannot be deployed at all.
    # So it warns loudly and prints the command that fixes it. The same choice is made below for a missing
    # flock.
    if ! { ( umask 0002; : >> "$LOCK_FILE" ) 2>/dev/null && [ -r "$LOCK_FILE" ]; }; then
        warn "не удалось создать файл блокировки $LOCK_FILE — продолжаю БЕЗ взаимоисключения."
        cont "Ручной откат, запущенный посреди этого деплоя, ничем не разведён с ним."
        cont "Починка на хосте (один раз): sudo chgrp <группа-раннера> $DEPLOY_DIR && sudo chmod 2775 $DEPLOY_DIR"
        return 0
    fi
    chmod 0664 "$LOCK_FILE" 2>/dev/null || true
    exec 9<"$LOCK_FILE"
    flock -n 9 || { die "деплой или откат уже выполняется — прерываю (блокировка $LOCK_FILE)"; exit 1; }
}

# The active colour is the one Caddy REALLY points at. The `active` file is advisory: it is written
# after `caddy reload`, so it lags behind a failed write and behind a hand-edited upstream during an
# incident. Getting this wrong is the most expensive mistake available: restarting the active colour
# is an outage for the whole JVM start, in the middle of a supposedly safe blue-green.
detect_active() {
    local port color noted
    # The port is anchored to the END of the line and only uncommented `to` directives count, or a comment
    # or a port such as 23331 would yield the wrong colour. The width is 2-5 digits rather than exactly
    # four: a service may well have a five-digit port, and a hard four would cut it off silently — the
    # deploy would stop at "cannot determine the active colour" on a perfectly healthy host.
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

# Readiness is checked through the readiness GROUP, not the /actuator/health aggregate: the aggregate
# includes redis and diskSpace, which would block the deploy of a fully working instance on an
# unreachable cache.
#
# The HTTP code is the gate: Actuator answers 200 for UP and 503 for DOWN or OUT_OF_SERVICE. The body
# is checked in addition, and only for the absence of non-UP statuses, to catch UNKNOWN — which also
# maps to 200.
#
# Nothing may assume key ORDER. The readiness group inherits show-details: always and answers
# `{"components":{...},"status":"UP"}` — components first. Anchoring on `^{"status":"UP"` therefore
# fails against a completely healthy instance, and the deploy sits out its whole budget before rolling
# back. JSON guarantees no key order at all.
is_healthy() {
    local url resp code body
    url="http://127.0.0.1:$(mgmt_port "$1")/actuator/health/readiness"
    # The code is appended to the body with no separator and cut off by position: a -w format without
    # escape sequences does not depend on how a particular curl expands them.
    resp="$(curl -s --max-time 5 -w '%{http_code}' "$url" 2>/dev/null)" || return 1
    code="${resp: -3}"
    body="${resp%???}"
    [ "$code" = "200" ] || return 1
    case "$body" in
        *'"status":"DOWN"'*|*'"status":"OUT_OF_SERVICE"'*|*'"status":"UNKNOWN"'*) return 1 ;;
    esac
    return 0
}

# Waits for readiness until the deadline, but leaves early once systemd has restarted the unit:
# Restart=on-failure means a build that dies at startup will come up again and again, so sitting out
# the rest of the budget proves nothing.
wait_healthy() {
    local color="$1" timeout="${2:-$HEALTH_TIMEOUT}" unit deadline nr0 nr
    unit="$SERVICE_UNIT@$color"
    nr0="$(systemctl show -p NRestarts --value "$unit" 2>/dev/null || true)"
    deadline=$(( $(date +%s) + timeout ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if is_healthy "$color"; then return 0; fi
        # A single automatic restart is tolerated: the application may have died on a transient database
        # outage and come up on the second try. Two or more is a loop.
        # The values are checked for being numeric: a non-numeric string inside $(( )) under set -u would kill
        # the script.
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

# Diagnostics for a colour that failed the readiness gate. "Did not come up in N seconds" does not
# separate two very different cases: the application is not listening at all, or it is listening and
# deliberately answering DOWN — an unreachable database in the readiness group, say. Without this,
# triage needs someone with ssh on the production host, which turns every red deploy into a
# conversation.
# All of it is best-effort: diagnostics must never affect the exit code.
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
    # Not every service has a smoke path. Without one there is nothing to call on the app port, and the
    # line is simply not printed — better than showing a 404 for a path that was invented here.
    if [ -n "${SMOKE_PATH:-}" ]; then
        echo "   app-порт $aport: код $(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
            "http://127.0.0.1:$aport$SMOKE_PATH" 2>/dev/null || echo 'нет соединения')"
    fi
    echo "   systemctl status $SERVICE_UNIT@$color:"
    systemctl status "$SERVICE_UNIT@$color" --no-pager -n 30 2>&1 | sed 's/^/     /' || true
    echo "-------------------------------------------------------------------------"
}

# The upstream is written through a temporary file: Caddy may read it while it is being edited, and a
# half-written `to 127.0.0.1:23` fails the reload.
switch_upstream() {
    printf 'to 127.0.0.1:%s\n' "$(app_port "$1")" > "$CADDY_UPSTREAM.tmp"
    chmod 0644 "$CADDY_UPSTREAM.tmp"
    mv -f "$CADDY_UPSTREAM.tmp" "$CADDY_UPSTREAM"
}

reload_caddy() { caddy reload --config "$CADDYFILE" --adapter caddyfile; }

# Traffic is switched ALWAYS through this primitive. The upstream file is the source of truth for the
# active colour (see detect_active), so it must not outlive a failed reload for even a second —
# otherwise the next deploy takes the wrong colour for live and restarts it under load.
# apply_upstream <new-colour> <previous-colour>
apply_upstream() {
    switch_upstream "$1"
    if ! reload_caddy; then
        die "caddy reload не прошёл — возвращаю апстрим на $2"
        switch_upstream "$2"
        reload_caddy || true
        return 1
    fi
}

# `active` is advisory — the source of truth is detect_active — so a failed write must not fail the
# script: traffic has already been switched by this point.
record_active() {
    printf '%s\n' "$1" > "$ACTIVE_FILE" 2>/dev/null \
        || warn "не удалось обновить $ACTIVE_FILE. Файл справочный, трафик уже на $1"
}
