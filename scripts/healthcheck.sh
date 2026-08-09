#!/bin/sh

# ==============================================================================
# Container healthcheck
# Reports healthy while the last successful run is recent enough.
# ==============================================================================

set -u

# Load all configuration (defaults, validation, normalization) from config.sh
# shellcheck disable=SC1091  # config.sh is linted separately (scripts/*.sh)
. "$(dirname "$0")/config.sh"

if [ ! -f "$STATUS_FILE" ]; then
    echo "no successful run recorded yet"
    exit 1
fi

NOW=$(date +%s)
MTIME=$(date -r "$STATUS_FILE" +%s 2>/dev/null)
[ -n "$MTIME" ] || exit 1

AGE=$((NOW - MTIME))
if [ "$AGE" -le "$HEALTHCHECK_MAX_AGE" ]; then
    exit 0
fi

echo "last successful run ${AGE}s ago"
exit 1
