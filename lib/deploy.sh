#!/usr/bin/env bash
#
# Blue-green деплой на сам сервер (без Docker), за Caddy. Оба цвета (blue/green) работают
# постоянно как тёплый резерв; Caddy в каждый момент проксирует на ОДИН активный цвет.
#
# Шаги: собранный jar → в каталог STANDBY-цвета → restart этого юнита → readiness-check (его
# management-порт) → сверка релиза на /actuator/info → смоук по app-порту → переключение Caddy
# на standby (`caddy reload`, graceful) → standby становится активным, прежний активный
# продолжает крутиться на старой версии (тёплый резерв / мгновенный откат).
# Если standby не поднялся — Caddy НЕ переключается, активный цвет обслуживает трафик без
# изменений, а standby возвращается на предыдущий jar, чтобы резерв не пропал.
#
# Использование: deploy/deploy.sh <путь-к-jar> <release-id>
# Переменные: HEALTH_TIMEOUT (сек, 600), RESTORE_TIMEOUT (180), KEEP_RELEASES (5),
#             ALLOW_SAME_RELEASE, SKIP_RELEASE_CHECK
set -euo pipefail

JAR_SRC="${1:?usage: deploy.sh <jar> <release-id>}"
RELEASE_ID="${2:?usage: deploy.sh <jar> <release-id>}"

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

RELEASES_DIR="$DEPLOY_DIR/releases"
KEEP_RELEASES="${KEEP_RELEASES:-5}"
RESTORE_TIMEOUT="${RESTORE_TIMEOUT:-180}"

# Битая сборка + Restart=on-failure = вечный цикл перезапусков, и тёплого резерва больше нет:
# rollback.sh будет некуда переключаться. Возвращаем предыдущий jar и поднимаем цвет на нём.
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

# Дежурный запускает откат руками, и путь до скриптов не должен зависеть от того, куда раннер
# разложил чекаут action'а (_work/_actions/<owner>/<repo>/<tag>/lib). Копия в $DEPLOY_DIR/bin —
# стабильный путь: /opt/backend/<сервис>/bin/rollback.sh.
# Всё best-effort: трафик к моменту вызова уже переключён, и неудачное копирование не имеет
# права покрасить успешный деплой.
install_bin() {
    local src bin f
    src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    bin="$DEPLOY_DIR/bin"
    mkdir -p "$bin" 2>/dev/null || { warn "не удалось создать $bin — откат придётся запускать из чекаута"; return 0; }
    # Профиль кладём именно как service.conf: lib.sh находит соседний файл с этим именем сам,
    # поэтому установленным скриптам не нужен SERVICE_PROFILE в окружении.
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

# Раскатка релиза, который уже обслуживает трафик, затирает единственную цель отката — тёплый
# резерв со старой версией. Обычно это повторный Re-run уже выехавшего деплоя.
if [ "$(release_of "$active")" = "$RELEASE_ID" ] && [ -z "${ALLOW_SAME_RELEASE:-}" ]; then
    die "$RELEASE_ID уже обслуживает трафик на $active: раскатка в $standby уничтожит"
    cont "единственную цель отката — резерв с предыдущей версией."
    cont "Если это осознанно, повторите запуск с ALLOW_SAME_RELEASE=1."
    exit 1
fi

mkdir -p "$RELEASES_DIR" "$DEPLOY_DIR/$standby"

# Архив сборки (release.sh катит из него же — тогда копировать файл в самого себя не нужно)
archived="$RELEASES_DIR/$RELEASE_ID.jar"
if [ "$(readlink -f "$JAR_SRC")" != "$(readlink -f "$archived")" ]; then
    install -m 0644 "$JAR_SRC" "$archived"
else
    # Освежаем метку: чистка ниже отбирает свежие по mtime, иначе только что выкаченная из
    # архива сборка первой же попала бы под удаление — и вернуться на неё стало бы нельзя.
    touch "$archived"
fi

# Страховка на случай неудачного старта новой сборки (см. restore_standby)
prev_jar="$DEPLOY_DIR/$standby/$JAR_NAME.prev"
if [ -f "$DEPLOY_DIR/$standby/$JAR_NAME" ]; then
    install -m 0644 "$DEPLOY_DIR/$standby/$JAR_NAME" "$prev_jar"
fi

# Атомарная подмена jar standby-цвета
install -m 0644 "$JAR_SRC" "$DEPLOY_DIR/$standby/$JAR_NAME.new"
mv -f "$DEPLOY_DIR/$standby/$JAR_NAME.new" "$DEPLOY_DIR/$standby/$JAR_NAME"

# Проверяем код рестарта явно: к этому моменту jar уже подменён, и голая команда под set -e
# оборвала бы скрипт ДО restore_standby, оставив резерв с неподнятой новой сборкой.
step "перезапускаю $SERVICE_UNIT@$standby на новой сборке; трафик пока на $active"
if ! sudo -n systemctl restart "$SERVICE_UNIT@$standby"; then
    die "не удалось перезапустить $SERVICE_UNIT@$standby"
    cont "Смотрите systemctl status $SERVICE_UNIT@$standby и права sudo у пользователя раннера."
    restore_standby "$standby" "$prev_jar"
    exit 1
fi

step "жду готовности $standby (не дольше ${HEALTH_TIMEOUT}с)"
if ! wait_healthy "$standby" "$HEALTH_TIMEOUT"; then
    # Про сам факт «не вышел в готовность» уже сказал wait_healthy — здесь только следствие.
    # Подсказку даём ДО диагностики: диагностика длинная, и человек должен сначала увидеть,
    # что прод цел, а уже потом разбираться.
    die "трафик НЕ переключаю, активен прежний $active — простоя нет"
    cont "Полный журнал: journalctl -u $SERVICE_UNIT@$standby -n 200 --no-pager"
    diagnose_color "$standby"
    restore_standby "$standby" "$prev_jar"
    exit 1
fi

# Проверяем, что отвечает ИМЕННО новая сборка: рестарт мог поднять старый jar (запись не
# прошла, юнит смотрит в другой каталог), а readiness этого не различает.
if [ -z "${SKIP_RELEASE_CHECK:-}" ]; then
    info="http://127.0.0.1:$(mgmt_port "$standby")/actuator/info"
    # RELEASE_ID — намеренно ПРЕФИКС полного SHA (deploy.yml запекает 40 символов, сюда
    # передаёт 12), поэтому сравнение префиксное, а не точное. Якорим на поле commit, чтобы
    # совпадение не поймалось где-нибудь в build.time.
    if ! curl -fsS --max-time 5 "$info" 2>/dev/null | grep -Fq "\"commit\":\"$RELEASE_ID"; then
        die "в $standby отвечает не та сборка: на $info нет commit=$RELEASE_ID."
        cont "Трафик НЕ переключаю, активен прежний $active."
        cont "Для сборки, собранной вручную без -Pgit.commit, повторите с SKIP_RELEASE_CHECK=1."
        exit 1
    fi
fi

# RELEASE пишем ЗДЕСЬ, а не после переключения: в этой точке уже доказано, какая сборка
# отвечает на порту цвета, а на сам caddy reload содержимое файла не влияет. Если писать
# позже, то упавший между reload и записью деплой оставил бы rollback.sh с меткой, по
# которой он «откатывается» на более новую сборку.
printf '%s\n' "$RELEASE_ID" > "$DEPLOY_DIR/$standby/RELEASE" \
    || warn "не удалось записать $DEPLOY_DIR/$standby/RELEASE. Метка справочная, деплой продолжается"

# Смоук по РЕАЛЬНОМУ порту приложения: management висит на отдельном сокете и не знает про
# base-path, поэтому неверный SERVER_PORT и сломанный base-path он не поймает. Путь и набор
# допустимых кодов задаёт профиль. Коды перечисляются через пробел, потому что «приложение
# отвечает» — далеко не всегда 200: сервис за фильтром локальной сети штатно отвечает на loopback
# 403/407, и такой ответ доказывает работоспособность ровно так же.
# Пустой SMOKE_PATH выключает шаг ЯВНО и с сообщением: молчаливый пропуск в логе читался бы
# как «смоук прошёл», хотя проверки не было вовсе.
if [ -n "${SMOKE_PATH:-}" ]; then
    probe="http://127.0.0.1:$(app_port "$standby")$SMOKE_PATH"
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$probe" || echo 000)"
    smoke_ok=0
    # shellcheck disable=SC2086  # SMOKE_EXPECT — намеренно список кодов через пробел
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

# `caddy reload` возвращает 0 по факту принятия конфига и ничего не говорит о том, что
# sites/api.caddy действительно импортирует active-upstream.caddy (импортов там два — общий
# у сервиса их может быть несколько — общий префикс и отдельные роуты, см. его README).
if caddy_config="$(curl -fsS --max-time 5 "$CADDY_ADMIN/config/" 2>/dev/null)"; then
    if ! printf '%s' "$caddy_config" | grep -q "127.0.0.1:$(app_port "$standby")"; then
        die "живой конфиг Caddy не содержит порт $standby — возвращаю апстрим на $active"
        cont "Вероятная причина: sites/api.caddy не импортирует $CADDY_UPSTREAM."
        switch_upstream "$active"
        reload_caddy || true
        exit 1
    fi
    # Порт прежнего цвета в живом конфиге = где-то остался литерал вместо import. Трафик
    # уже частично уехал, откатывать поздно и незачем — но знать об этом надо, поэтому
    # предупреждение, а не отказ (иначе недомигрированный sites/api.caddy заблокировал бы
    # любой деплой, а какой именно он на хосте — из репозитория не видно).
    if printf '%s' "$caddy_config" | grep -q "127.0.0.1:$(app_port "$active")"; then
        warn "в живом конфиге Caddy остался и порт прежнего цвета $active."
        cont "Вероятно, часть маршрутов задаёт апстрим литералом вместо import $CADDY_UPSTREAM."
    fi
else
    warn "admin API Caddy ($CADDY_ADMIN) недоступен — проверку живого конфига пропускаю"
fi

record_active "$standby"

# Скрипты обновляем ТОЛЬКО после успешного переключения. Сборка, не прошедшая гейты, свои
# скрипты ничем не подтвердила, а дежурному нужен откат, который заведомо работает — поэтому
# в $DEPLOY_DIR/bin всегда лежит версия последнего УДАЧНОГО деплоя, ровно та, которой поднят
# текущий релиз.
install_bin

rm -f "$prev_jar"
step "готово: активен $standby ($RELEASE_ID), тёплый резерв — $active ($(release_of "$active"))"

# Чистка архива сборок (оставляем KEEP_RELEASES свежих) — best-effort: это последняя команда
# скрипта, и её код возврата иначе стал бы кодом уже переключённого деплоя.
if ! { ls -1t "$RELEASES_DIR"/*.jar 2>/dev/null | tail -n +"$((KEEP_RELEASES + 1))" | xargs -r rm -f; }; then
    warn "не удалось почистить архив $RELEASES_DIR. Деплой при этом успешен"
fi
exit 0
