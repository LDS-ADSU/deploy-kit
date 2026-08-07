#!/usr/bin/env bash
#
# Мгновенный откат blue-green: переключить Caddy на другой цвет (тёплый резерв, на котором ещё
# крутится предыдущая версия). Резерв работает постоянно, поэтому в норме откат — это один
# `caddy reload`, без рестарта и без простоя.
#
# Рестартуем резерв ТОЛЬКО если он не отвечает: гасить живой резерв в аварийной ситуации — худшее
# из возможных действий, пока он поднимается, откатываться будет некуда.
#
# Откат работает «на один шаг назад». Если оба цвета уже несут новый код (два деплоя подряд),
# нужен откат на конкретную сборку из архива — deploy/release.sh <release-id>.
#
# Использование: deploy/rollback.sh
# Переменные: HEALTH_TIMEOUT (сек, 600)
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

acquire_switch_lock

active="$(detect_active)"
target="$(other "$active")"
step "откат: $active ($(release_of "$active")) → $target ($(release_of "$target"))"

# Решение «рестартовать резерв или нет» принимаем не по одной пробе: единичный таймаут на
# занятом хосте иначе стоил бы нам как раз того, ради чего этот скрипт и переписан.
healthy=0
for _ in 1 2 3; do
    if is_healthy "$target"; then healthy=1; break; fi
    sleep 2
done

if [ "$healthy" -eq 1 ]; then
    step "$target уже здоров — переключаю апстрим без рестарта, откат мгновенный"
else
    step "$target не отвечает — поднимаю его; откат будет не мгновенным (до ${HEALTH_TIMEOUT}с)"
    sudo -n systemctl restart "$SERVICE_UNIT@$target" \
        || { die "не удалось перезапустить $SERVICE_UNIT@$target: откат прерван, активен $active"; exit 1; }
    wait_healthy "$target" "$HEALTH_TIMEOUT" \
        || { die "$target не вышел в готовность: откат прерван, активен $active"; exit 1; }
fi

apply_upstream "$target" "$active" || { die "откат не выполнен, активен прежний $active"; exit 1; }
record_active "$target"
step "откат выполнен: активен $target ($(release_of "$target"))"
