#!/usr/bin/env bash
#
# Instant blue-green rollback: point Caddy at the other colour, the warm reserve still running the
# previous version. The reserve runs continuously, so a rollback is normally a single `caddy reload` —
# no restart and no downtime.
#
# The reserve is restarted ONLY if it does not answer: taking down a live reserve during an incident is
# the worst available move, because while it comes up there is nowhere to roll back to.
#
# A rollback goes exactly one step back. If both colours already carry new code — two deploys in a row
# — the way back to a particular build is deploy/release.sh <release-id>.
#
# Usage: deploy/rollback.sh
# Variables: HEALTH_TIMEOUT (seconds, 600)
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

acquire_switch_lock

active="$(detect_active)"
target="$(other "$active")"
step "откат: $active ($(release_of "$active")) → $target ($(release_of "$target"))"

# Whether to restart the reserve is not decided on one probe: a single timeout on a busy host would
# otherwise cost exactly the thing this script exists to protect.
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
