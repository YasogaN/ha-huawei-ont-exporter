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

export ONT_HOST ONT_USER ONT_PASS

# ------------------------------------------------------------------------------
# 1. Collect stats & parse
# ------------------------------------------------------------------------------
RAW_OUTPUT=$("$STATS_SCRIPT" 2>&1)
STATS_EXIT_CODE=$?

if [ "$STATS_EXIT_CODE" -ne 0 ]; then
    log "ERROR" "Stats script failed with exit code $STATS_EXIT_CODE"
    exit 1
fi

PARSED_JSON=$(printf '%s\n' "$RAW_OUTPUT" | awk -v wan="$WAN_INTERFACE" '
    index($0, wan " packet statistic:") > 0 { found=1; in_wan=1; next }
    /-----------------------------------------/ { if (in_wan) in_wan=0 }
    in_wan && /^[ \t]*BytesSent[ \t]*:/ { split($0, a, ":"); bytes_sent=a[2]; gsub(/[ \t\r\n]/, "", bytes_sent) }
    in_wan && /^[ \t]*BytesReceived[ \t]*:/ { split($0, b, ":"); bytes_recv=b[2]; gsub(/[ \t\r\n]/, "", bytes_recv) }
    in_wan && /^[ \t]*FrameSent[ \t]*:/ { split($0, f, ":"); frames_sent=f[2]; gsub(/[ \t\r\n]/, "", frames_sent) }
    in_wan && /^[ \t]*FrameReceived[ \t]*:/ { split($0, g, ":"); frames_recv=g[2]; gsub(/[ \t\r\n]/, "", frames_recv) }
    END {
        if (found)
            printf "{\"bytes_sent\":%s,\"bytes_received\":%s,\"frames_sent\":%s,\"frames_received\":%s}\n",
                (bytes_sent=="" ? 0 : bytes_sent), (bytes_recv=="" ? 0 : bytes_recv),
                (frames_sent=="" ? 0 : frames_sent), (frames_recv=="" ? 0 : frames_recv)
    }
')

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
deduct() {
    raw="$1"
    frames="$2"
    net=$((raw - frames * OVERHEAD_PER_FRAME))
    if [ "$net" -lt 0 ]; then
        log "WARN" "Overhead deduction produced a negative value (raw=$raw frames=$frames); clamping to 0"
        net=0
    fi
    echo "$net"
}

NET_SENT=$(deduct "$BYTES_SENT" "$FRAMES_SENT")
NET_RECV=$(deduct "$BYTES_RECV" "$FRAMES_RECV")
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
    payload=$(printf '{"state":"%s","attributes":{"unit_of_measurement":"B","device_class":"data_size","state_class":"total_increasing","friendly_name":"%s","raw_bytes":%s,"frames":%s,"overhead_per_frame":%d}}' \
        "$state" "$name" "$raw" "$frames" "$OVERHEAD_PER_FRAME")

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
