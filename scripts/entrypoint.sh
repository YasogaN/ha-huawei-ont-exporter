#!/bin/sh

# ==============================================================================
# Container entrypoint
#
# Default behaviour: run the exporter in a loop every INTERVAL seconds.
# If a command is provided as an argument (e.g. a one-shot run), it is
# executed instead. This allows `podman run ... /app/main.sh` for a single run.
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
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting Huawei ONT exporter loop (every ${INTERVAL}s)"

while :; do
    /app/main.sh || true
    sleep "$INTERVAL"
done
