#!/usr/bin/env bash
#
# Runs the harness against EVERY profile at once — the point of the kit: one blue-green implementation
# checked against all five services, instead of five copies each checked against one.
#
#   test/matrix.sh
#
# One line per profile. Full output only for a failure, or five runs turn the log into a wall in which
# the single red line is lost.
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
