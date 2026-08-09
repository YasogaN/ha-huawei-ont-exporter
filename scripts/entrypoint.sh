#!/bin/sh

# ==============================================================================
# Container entrypoint
#
# Default behaviour: run the exporter in a loop every INTERVAL seconds, backing
# off exponentially after consecutive failures. If a command is provided as an
# argument (e.g. a one-shot run), it is executed instead. This allows
# `podman run ... /app/main.sh` for a single run.
# ==============================================================================

set -eu

if [ "$#" -gt 0 ]; then
    exec "$@"
fi

# Load all configuration (defaults, validation, normalization) from config.sh.
# Done after the one-shot exec above so one-shot runs are not double-validated.
# shellcheck disable=SC1091  # config.sh is linted separately (scripts/*.sh)
. "$(dirname "$0")/config.sh"

require HA_IP HA_TOKEN ONT_HOST ONT_USER ONT_PASS

# The ONT only allows one SSH session and holds it briefly after each poll, so
# never poll faster than once a minute (enforced in config.sh).
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting Huawei ONT exporter loop (every ${INTERVAL}s)"

FAILURES=0
while :; do
    if /app/main.sh; then
        FAILURES=0
        sleep "$INTERVAL"
    else
        FAILURES=$((FAILURES + 1))
        DELAY=$INTERVAL
        N=$FAILURES
        while [ "$N" -gt 1 ]; do
            DELAY=$((DELAY * 2))
            N=$((N - 1))
        done
        [ "$DELAY" -gt "$MAX_BACKOFF" ] && DELAY=$MAX_BACKOFF
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] ${FAILURES} consecutive failure(s); backing off ${DELAY}s"
        sleep "$DELAY"
    fi
done
