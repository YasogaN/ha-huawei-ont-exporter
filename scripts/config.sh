#!/bin/sh

# ==============================================================================
# Central configuration loader for the Huawei ONT exporter.
#
# Sourced by every script. Reads all settings from the environment, applies
# defaults, normalizes boolean values, and validates types and ranges. Each
# script then calls `require` for the variables it actually needs, so a script
# can run standalone with a minimal environment (e.g. get_stats.sh does not
# need the HA_* variables).
#
# All of this runs at source time and is safe under `set -u`.
# ==============================================================================

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

config_error() {
    echo "[config] ERROR: $*" >&2
    exit 1
}

config_warn() {
    echo "[config] WARN: $*" >&2
}

# Fail if a required variable is unset or empty. Accepts one or more names.
require() {
    for var in "$@"; do
        eval "value=\${$var-}"
        if [ -z "$value" ]; then
            config_error "$var is required but not set (check .env)"
        fi
    done
}

# Fail if a variable is not a positive integer.
require_int() {
    var="$1"
    eval "value=\${$var-}"
    case "$value" in
        ''|*[!0-9]*) config_error "$var must be a positive integer (got '$value')" ;;
    esac
}

# Normalize a boolean-ish value to the canonical string 'true'/'false'.
normalize_bool() {
    var="$1"
    eval "value=\${$var-}"
    case "$value" in
        true|True|TRUE|1|yes|on)   eval "$var=true" ;;
        false|False|FALSE|0|no|off) eval "$var=false" ;;
        *) config_error "$var has invalid value '$value' (expected true/false)" ;;
    esac
}

# ------------------------------------------------------------------------------
# Defaults
# ------------------------------------------------------------------------------

# Home Assistant
: "${HA_PORT:=8123}"
: "${HA_SCHEME:=http}"

# Huawei ONT
: "${WAN_INTERFACE:=wan1}"
: "${STATS_SCRIPT:=/app/get_stats.sh}"

# Exporter behaviour
: "${DRY_RUN:=false}"
: "${STATUS_FILE:=/tmp/huawei_ont_exporter_status}"
: "${VLAN_ENABLED:=true}"
: "${PPPOE_ENABLED:=false}"

# Poll loop
: "${INTERVAL:=60}"
: "${MAX_BACKOFF:=3600}"

# SSH session handling (get_stats.sh)
: "${PROMPT_TIMEOUT:=15}"
: "${OUTPUT_TIMEOUT:=20}"
: "${COMMAND_ATTEMPTS:=3}"
: "${AUTO_KILL_SESSIONS:=true}"
: "${CLOSE_GRACE:=3}"

# Healthcheck
: "${HEALTHCHECK_MAX_AGE:=300}"

# ------------------------------------------------------------------------------
# Type validation
# ------------------------------------------------------------------------------
require_int HA_PORT
require_int INTERVAL
require_int MAX_BACKOFF
require_int PROMPT_TIMEOUT
require_int OUTPUT_TIMEOUT
require_int COMMAND_ATTEMPTS
require_int CLOSE_GRACE
require_int HEALTHCHECK_MAX_AGE

# ------------------------------------------------------------------------------
# Boolean normalization
# ------------------------------------------------------------------------------
normalize_bool DRY_RUN
normalize_bool VLAN_ENABLED
normalize_bool PPPOE_ENABLED
normalize_bool AUTO_KILL_SESSIONS

# ------------------------------------------------------------------------------
# Range validation
# ------------------------------------------------------------------------------

# The ONT only allows one SSH session and holds it briefly after each poll, so
# never poll faster than once a minute.
if [ "$INTERVAL" -lt 60 ]; then
    config_warn "INTERVAL of ${INTERVAL}s is below the 60s minimum; using 60s"
    INTERVAL=60
fi
