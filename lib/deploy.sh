#!/usr/bin/env bash
#
# Blue-green deploy onto the host itself, no Docker, behind Caddy. Both colours run continuously as a
# warm reserve; Caddy proxies to exactly ONE of them at a time.
#
# The steps: put the built jar in the STANDBY colour's directory, restart that unit, wait for
# readiness on its management port, confirm the release on /actuator/info, smoke-test the app port,
# then switch Caddy to standby with a graceful `caddy reload`. Standby becomes active and the previous
# active keeps running the old version as a warm reserve and an instant rollback.
#
# If standby does not come up, Caddy is NOT switched: the active colour serves traffic unchanged, and
# standby is put back on its previous jar so the reserve does not disappear.
#
# Usage: deploy/deploy.sh <path-to-jar> <release-id>
# Variables: HEALTH_TIMEOUT (seconds, 600), RESTORE_TIMEOUT (180), KEEP_RELEASES (5),
#             ALLOW_SAME_RELEASE, SKIP_RELEASE_CHECK
set -euo pipefail

JAR_SRC="${1:?usage: deploy.sh <jar> <release-id>}"
RELEASE_ID="${2:?usage: deploy.sh <jar> <release-id>}"

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

RELEASES_DIR="$DEPLOY_DIR/releases"
KEEP_RELEASES="${KEEP_RELEASES:-5}"
RESTORE_TIMEOUT="${RESTORE_TIMEOUT:-180}"

# A broken build plus Restart=on-failure is an endless restart loop, and the warm reserve is gone with
# it: rollback.sh would have nowhere to switch to. The previous jar goes back and the colour comes up
# on it.
restore_standby() {
    local color="$1" prev="$2"
    if [ -f "$prev" ]; then
        cont "Возвращаю предыдущую сборку в $color, чтобы резерв остался живым."
        mv -f "$prev" "$DEPLOY_DIR/$color/$JAR_NAME"
        if sudo -n systemctl restart "$SERVICE_UNIT@$color" && wait_healthy "$color" "$RESTORE_TIMEOUT"; then
            cont "$color снова здоров на предыдущей версии ($(release_of "$color"))."
        else
            cont "Значит дело не в новой сборке. Резерва сейчас нет."
            diagnose_color "$color"
        fi
    else
        cont "Предыдущей сборки нет, поэтому останавливаю $color: иначе systemd будет"
        cont "перезапускать неработающую сборку до следующего деплоя."
        sudo -n systemctl stop "$SERVICE_UNIT@$color" \
            || cont "Остановить не удалось: добавьте 'systemctl stop $SERVICE_UNIT@$color' в sudoers."
    fi
}

# On-call runs a rollback by hand, and the path to the scripts must not depend on where the runner
# unpacked the action's checkout. The copy in $DEPLOY_DIR/bin is the stable one:
# /opt/backend/<service>/bin/rollback.sh.
# Best-effort: traffic has already been switched by this point, so a failed copy has no right to fail
# a successful deploy.
install_bin() {
    local src bin f
    src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    bin="$DEPLOY_DIR/bin"
    mkdir -p "$bin" 2>/dev/null || { warn "не удалось создать $bin — откат придётся запускать из чекаута"; return 0; }
    # The profile is installed under exactly the name service.conf: lib.sh finds a neighbouring file by
    # that name on its own, so the installed scripts need no SERVICE_PROFILE in their environment.
    install -m 0644 "$SERVICE_PROFILE" "$bin/service.conf" 2>/dev/null \
        || { warn "не удалось положить профиль в $bin — откат оттуда не заработает"; return 0; }
    install -m 0644 "$src/lib.sh" "$bin/lib.sh" 2>/dev/null || warn "не удалось положить lib.sh в $bin"
    for f in deploy.sh rollback.sh release.sh; do
        install -m 0755 "$src/$f" "$bin/$f" 2>/dev/null || warn "не удалось положить $f в $bin"
    done
    step "скрипты обновлены в $bin (откат: $bin/rollback.sh)"
}

acquire_switch_lock

active="$(detect_active)"
standby="$(other "$active")"
step "активен $active ($(release_of "$active")) → раскатываю $RELEASE_ID в резервный $standby"

# Rolling out a release that already serves traffic destroys the only thing a rollback aims at: the
# warm reserve running the previous version. Usually this is a re-run of a deploy that already
# shipped.
if [ "$(release_of "$active")" = "$RELEASE_ID" ] && [ -z "${ALLOW_SAME_RELEASE:-}" ]; then
    die "$RELEASE_ID уже обслуживает трафик на $active: раскатка в $standby уничтожит"
    cont "единственную цель отката — резерв с предыдущей версией."
    cont "Если это осознанно, повторите запуск с ALLOW_SAME_RELEASE=1."
    exit 1
fi

mkdir -p "$RELEASES_DIR" "$DEPLOY_DIR/$standby"

# The build archive. release.sh deploys straight out of it, so the file is not copied onto itself.
archived="$RELEASES_DIR/$RELEASE_ID.jar"
if [ "$(readlink -f "$JAR_SRC")" != "$(readlink -f "$archived")" ]; then
    install -m 0644 "$JAR_SRC" "$archived"
else
    # The mtime is refreshed: the sweep below keeps the newest by mtime, so a build just deployed out of
    # the archive would otherwise be the first one deleted — and there would be no going back to it.
    touch "$archived"
fi

# The fallback if the new build fails to start; see restore_standby.
prev_jar="$DEPLOY_DIR/$standby/$JAR_NAME.prev"
if [ -f "$DEPLOY_DIR/$standby/$JAR_NAME" ]; then
    install -m 0644 "$DEPLOY_DIR/$standby/$JAR_NAME" "$prev_jar"
fi

# The standby colour's jar is swapped atomically.
install -m 0644 "$JAR_SRC" "$DEPLOY_DIR/$standby/$JAR_NAME.new"
mv -f "$DEPLOY_DIR/$standby/$JAR_NAME.new" "$DEPLOY_DIR/$standby/$JAR_NAME"

# The restart's exit code is checked explicitly: the jar has already been swapped, and a bare command
# under set -e would end the script BEFORE restore_standby, leaving the reserve holding a build that
# does not start.
step "перезапускаю $SERVICE_UNIT@$standby на новой сборке; трафик пока на $active"
if ! sudo -n systemctl restart "$SERVICE_UNIT@$standby"; then
    die "не удалось перезапустить $SERVICE_UNIT@$standby"
    cont "Смотрите systemctl status $SERVICE_UNIT@$standby и права sudo у пользователя раннера."
    restore_standby "$standby" "$prev_jar"
    exit 1
fi

step "жду готовности $standby (не дольше ${HEALTH_TIMEOUT}с)"
if ! wait_healthy "$standby" "$HEALTH_TIMEOUT"; then
    # wait_healthy has already reported that readiness was not reached; this is only the consequence.
    # The reassurance comes BEFORE the diagnostics, which are long: the reader should see that production
    # is intact first and investigate afterwards.
    die "трафик НЕ переключаю, активен прежний $active — простоя нет"
    cont "Полный журнал: journalctl -u $SERVICE_UNIT@$standby -n 200 --no-pager"
    diagnose_color "$standby"
    restore_standby "$standby" "$prev_jar"
    exit 1
fi

# Confirms that the build answering is the NEW one: a restart may have brought up the old jar — the
# write failed, or the unit points at another directory — and readiness cannot tell the difference.
if [ -z "${SKIP_RELEASE_CHECK:-}" ]; then
    info="http://127.0.0.1:$(mgmt_port "$standby")/actuator/info"
    # RELEASE_ID is deliberately a PREFIX of the full SHA — deploy.yml bakes in 40 characters and passes
    # 12 here — so the comparison is by prefix, not equality. It is anchored to the commit field so a
    # match cannot come from somewhere in build.time.
    if ! curl -fsS --max-time 5 "$info" 2>/dev/null | grep -Fq "\"commit\":\"$RELEASE_ID"; then
        die "в $standby отвечает не та сборка: на $info нет commit=$RELEASE_ID."
        cont "Трафик НЕ переключаю, активен прежний $active."
        cont "Для сборки, собранной вручную без -Pgit.commit, повторите с SKIP_RELEASE_CHECK=1."
        exit 1
    fi
fi

# RELEASE is written HERE rather than after the switch: at this point it is proven which build answers
# on the colour's port, and the file's contents do not affect `caddy reload` at all. Written later, a
# deploy that dies between the reload and the write would leave rollback.sh with a marker that rolls
# "back" onto a newer build.
printf '%s\n' "$RELEASE_ID" > "$DEPLOY_DIR/$standby/RELEASE" \
    || warn "не удалось записать $DEPLOY_DIR/$standby/RELEASE. Метка справочная, деплой продолжается"

# The smoke test hits the REAL application port: management listens on its own socket and knows
# nothing about the base path, so it would catch neither a wrong SERVER_PORT nor a broken base path.
# The path and the acceptable codes come from the profile. The codes are a space-separated list
# because "the application answers" is often not 200: a service behind a local-network filter answers
# 403 or 407 on loopback as designed, and that proves it works just as well.
# An empty SMOKE_PATH disables the step EXPLICITLY and says so: a silent skip reads in the log as a
# smoke test that passed, when none ran.
if [ -n "${SMOKE_PATH:-}" ]; then
    probe="http://127.0.0.1:$(app_port "$standby")$SMOKE_PATH"
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$probe" || echo 000)"
    smoke_ok=0
    # shellcheck disable=SC2086  # SMOKE_EXPECT is deliberately a space-separated list of codes
    for want in ${SMOKE_EXPECT:-200}; do
        if [ "$code" = "$want" ]; then smoke_ok=1; fi
    done
    if [ "$smoke_ok" -eq 1 ]; then
        step "проба $probe вернула $code — приложение отвечает"
    else
        die "проба $probe вернула $code, ожидались ${SMOKE_EXPECT:-200}: трафик НЕ переключаю"
        cont "Активен прежний $active, простоя нет."
        exit 1
    fi
else
    step "смоук по app-порту не настроен (SMOKE_PATH пуст) — пропускаю"
fi

step "переключаю Caddy на $standby (порт $(app_port "$standby"))"
apply_upstream "$standby" "$active" || exit 1

# `caddy reload` returns 0 once the config is accepted and says nothing about whether sites/api.caddy
# actually imports active-upstream.caddy — a service may have several imports, a shared prefix and
# separate routes; see its README.
if caddy_config="$(curl -fsS --max-time 5 "$CADDY_ADMIN/config/" 2>/dev/null)"; then
    if ! printf '%s' "$caddy_config" | grep -q "127.0.0.1:$(app_port "$standby")"; then
        die "живой конфиг Caddy не содержит порт $standby — возвращаю апстрим на $active"
        cont "Вероятная причина: sites/api.caddy не импортирует $CADDY_UPSTREAM."
        switch_upstream "$active"
        reload_caddy || true
        exit 1
    fi
    # The previous colour's port in the live config means a literal was left somewhere instead of an
    # import. Traffic has already partly moved, so rolling back is both too late and pointless — but
    # someone has to know, hence a warning rather than a refusal. A refusal would let a half-migrated
    # sites/api.caddy block every deploy, and what that file looks like on the host is not visible from
    # the repository.
    if printf '%s' "$caddy_config" | grep -q "127.0.0.1:$(app_port "$active")"; then
        warn "в живом конфиге Caddy остался и порт прежнего цвета $active."
        cont "Вероятно, часть маршрутов задаёт апстрим литералом вместо import $CADDY_UPSTREAM."
    fi
else
    warn "admin API Caddy ($CADDY_ADMIN) недоступен — проверку живого конфига пропускаю"
fi

record_active "$standby"

# The scripts are updated ONLY after a successful switch. A build that failed its gates has proven
# nothing about its own scripts, and on-call needs a rollback that is known to work — so
# $DEPLOY_DIR/bin always holds the version from the last SUCCESSFUL deploy, the one that brought up
# the current release.
install_bin

rm -f "$prev_jar"
step "готово: активен $standby ($RELEASE_ID), тёплый резерв — $active ($(release_of "$active"))"

# Sweeping the build archive down to KEEP_RELEASES is best-effort: this is the script's last command,
# and its exit code would otherwise become the exit code of an already-switched deploy.
if ! { ls -1t "$RELEASES_DIR"/*.jar 2>/dev/null | tail -n +"$((KEEP_RELEASES + 1))" | xargs -r rm -f; }; then
    warn "не удалось почистить архив $RELEASES_DIR. Деплой при этом успешен"
fi
exit 0
