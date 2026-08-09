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

: "${HA_TOKEN:?HA_TOKEN environment variable is required}"
: "${ONT_HOST:?ONT_HOST environment variable is required}"
: "${ONT_USER:?ONT_USER environment variable is required}"
: "${ONT_PASS:?ONT_PASS environment variable is required}"

INTERVAL="${INTERVAL:-60}"
: "${MAX_BACKOFF:=3600}"

# The ONT only allows one SSH session and holds it briefly after each poll, so
# never poll faster than once a minute.
if [ "$INTERVAL" -lt 60 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] INTERVAL of ${INTERVAL}s is below the 60s minimum; using 60s"
    INTERVAL=60
fi

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
