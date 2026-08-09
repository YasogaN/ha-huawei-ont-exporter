#!/bin/sh

# ==============================================================================
# Huawei ONT bandwidth exporter for Home Assistant
#
# Connects to the Huawei ONT over SSH (via dbclient), reads the WAN packet
# statistics, subtracts the per-frame wire overhead, and pushes the corrected
# byte counters to the Home Assistant REST API.
#
# All settings come from environment variables (set in .env).
# ==============================================================================

set -u

# Load all configuration (defaults, validation, normalization) from config.sh
# shellcheck disable=SC1091  # config.sh is linted separately (scripts/*.sh)
. "$(dirname "$0")/config.sh"
# shellcheck disable=SC1091  # parse_stats.sh is linted separately (scripts/*.sh)
. "$(dirname "$0")/parse_stats.sh"

require HA_IP HA_TOKEN ONT_HOST ONT_USER ONT_PASS

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2"
}

# Per-frame overhead deduction. Each frame on the wire carries bytes that are
# not user data; the ONT's byte counters include them, the frame counters do
# not. Deduct per frame to get the real usable bytes.
#
#   Physical layer  : preamble + SFD (8) + inter-frame gap (12) = 20
#   Data link       : Ethernet MAC header (14) + FCS/CRC32 (4)  = 18
#                     -> 20 + 18 = 38 bytes per frame (always)
#   802.1Q VLAN tag : 4 bytes per frame when in use (most ISPs)
#   PPPoE           : PPPoE header (6) + PPP protocol ID (2) = 8 bytes when used
#
# VLAN tagging is enabled by default (near-universal on WAN services).
# PPPoE is ISP-specific and off by default. Both are normalized to true/false
# by config.sh.
if [ "$VLAN_ENABLED" = true ]; then VLAN_BYTES=4; else VLAN_BYTES=0; fi
if [ "$PPPOE_ENABLED" = true ]; then PPPOE_BYTES=8; else PPPOE_BYTES=0; fi

OVERHEAD_PER_FRAME=$((38 + VLAN_BYTES + PPPOE_BYTES))

log "INFO" "Config: HA=${HA_SCHEME}://${HA_IP}:${HA_PORT} (token: ${#HA_TOKEN} chars)"
log "INFO" "       ONT=${ONT_HOST} user=${ONT_USER} (pass: ${#ONT_PASS} chars) wan=${WAN_INTERFACE}"
log "INFO" "       vlan=${VLAN_ENABLED} pppoe=${PPPOE_ENABLED} overhead=${OVERHEAD_PER_FRAME} B/frame dry_run=${DRY_RUN}"
log "INFO" "       interval=${INTERVAL}s max_backoff=${MAX_BACKOFF}s status_file=${STATUS_FILE} health_max_age=${HEALTHCHECK_MAX_AGE}s"

export ONT_HOST ONT_USER ONT_PASS

# ------------------------------------------------------------------------------
# 1. Collect stats & parse
# ------------------------------------------------------------------------------
RAW_OUTPUT=$("$STATS_SCRIPT" 2>&1)
STATS_EXIT_CODE=$?

if [ "$STATS_EXIT_CODE" -ne 0 ]; then
    log "ERROR" "Stats script failed with exit code $STATS_EXIT_CODE"
    # get_stats.sh wraps its failures in === FAILURE SESSION LOG === markers;
    # surface that output here so the container logs show why it failed.
    log "ERROR" "Session output:"
    printf '%s\n' "$RAW_OUTPUT"
    exit 1
fi

PARSED_JSON=$(printf '%s\n' "$RAW_OUTPUT" | parse_stats "$WAN_INTERFACE")

if [ -z "$PARSED_JSON" ]; then
    log "ERROR" "Could not find WAN interface '$WAN_INTERFACE' in ONT output"
    exit 1
fi

extract() {
    printf '%s' "$PARSED_JSON" | sed -n "s/.*\"$1\":\([0-9]*\).*/\1/p"
}

BYTES_SENT=$(extract bytes_sent)
BYTES_RECV=$(extract bytes_received)
FRAMES_SENT=$(extract frames_sent)
FRAMES_RECV=$(extract frames_received)

# ------------------------------------------------------------------------------
# 2. Deduct per-frame wire overhead
# ------------------------------------------------------------------------------
NET_SENT=$(deduct_overhead "$BYTES_SENT" "$FRAMES_SENT" "$OVERHEAD_PER_FRAME")
NET_RECV=$(deduct_overhead "$BYTES_RECV" "$FRAMES_RECV" "$OVERHEAD_PER_FRAME")
NET_TOTAL=$((NET_SENT + NET_RECV))
RAW_TOTAL=$((BYTES_SENT + BYTES_RECV))
FRAMES_TOTAL=$((FRAMES_SENT + FRAMES_RECV))

log "INFO" "Read stats for $WAN_INTERFACE (overhead ${OVERHEAD_PER_FRAME} B/frame):"
log "INFO" "  sent:     raw=$BYTES_SENT B / ${FRAMES_SENT} frames -> $NET_SENT B"
log "INFO" "  received: raw=$BYTES_RECV B / ${FRAMES_RECV} frames -> $NET_RECV B"

# ------------------------------------------------------------------------------
# 3. Push to the Home Assistant API
# ------------------------------------------------------------------------------
push_state() {
    entity="$1"
    state="$2"
    name="$3"
    raw="$4"
    frames="$5"
    payload=$(sensor_payload "$state" "$name" "$raw" "$frames" "$OVERHEAD_PER_FRAME")

    # busybox wget has no built-in retry; retry manually. Exit 0 on success,
    # non-zero (network failure or HTTP error) otherwise.
    for attempt in 1 2 3 4; do
        wget -q -T 20 -O /dev/null \
            --header="Authorization: Bearer ${HA_TOKEN}" \
            --header="Content-Type: application/json" \
            --post-data="$payload" \
            "${HA_SCHEME}://${HA_IP}:${HA_PORT}/api/states/${entity}"
        rc=$?
        [ "$rc" -eq 0 ] && return 0
        [ "$attempt" -lt 4 ] && sleep 2
    done

    log "ERROR" "Failed to push ${entity} to Home Assistant (wget exit $rc)"
    return 1
}

mark_success() {
    date +%s > "$STATUS_FILE" 2>/dev/null || true
}

if [ "$DRY_RUN" = true ]; then
    log "INFO" "DRY RUN - skipping Home Assistant updates"
    log "INFO" "  would push received=$NET_RECV sent=$NET_SENT total=$NET_TOTAL"
    mark_success
    exit 0
fi

FAILURES=0
push_state "sensor.huawei_ont_bytes_received" "$NET_RECV" "Huawei ONT Download Bytes" "$BYTES_RECV" "$FRAMES_RECV" || FAILURES=$((FAILURES + 1))
push_state "sensor.huawei_ont_bytes_sent"     "$NET_SENT" "Huawei ONT Upload Bytes"     "$BYTES_SENT" "$FRAMES_SENT" || FAILURES=$((FAILURES + 1))
push_state "sensor.huawei_ont_bytes_total"     "$NET_TOTAL" "Huawei ONT Total Bytes"      "$RAW_TOTAL" "$FRAMES_TOTAL" || FAILURES=$((FAILURES + 1))

if [ "$FAILURES" -eq 0 ]; then
    log "INFO" "Successfully pushed Huawei ONT stats to Home Assistant."
    mark_success
else
    log "ERROR" "$FAILURES of 3 sensor updates failed."
    exit 1
fi
