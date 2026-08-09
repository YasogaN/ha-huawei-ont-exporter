#!/bin/bash

# ==============================================================================
# Huawei ONT bandwidth exporter for Home Assistant
#
# Connects to the Huawei ONT over SSH (via expect), reads the WAN packet
# statistics, subtracts the per-frame wire overhead, and pushes the corrected
# byte counters to the Home Assistant REST API.
#
# All settings come from environment variables (set in .env).
# ==============================================================================

set -u

# ------------------------------------------------------------------------------
# Required configuration
# ------------------------------------------------------------------------------
: "${HA_IP:?HA_IP is required}"
: "${HA_TOKEN:?HA_TOKEN is required}"
: "${ONT_HOST:?ONT_HOST is required}"
: "${ONT_USER:?ONT_USER is required}"
: "${ONT_PASS:?ONT_PASS is required}"

# ------------------------------------------------------------------------------
# Optional configuration
# ------------------------------------------------------------------------------
: "${HA_PORT:=8123}"
: "${HA_SCHEME:=http}"
: "${WAN_INTERFACE:=wan1}"
: "${EXPECT_SCRIPT:=/app/get_stats.exp}"

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
# PPPoE is ISP-specific and off by default.
: "${VLAN_ENABLED:=true}"
: "${PPPOE_ENABLED:=false}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2"
}

bool_bytes() {
    local var="$1" value="$2" bytes="$3"
    case "$value" in
        true|True|TRUE|1|yes|on)  echo "$bytes" ;;
        false|False|FALSE|0|no|off) echo 0 ;;
        *) log "ERROR" "Invalid $var value: '$value' (expected true/false)"; exit 1 ;;
    esac
}

VLAN_BYTES=$(bool_bytes VLAN_ENABLED "$VLAN_ENABLED" 4)
PPPOE_BYTES=$(bool_bytes PPPOE_ENABLED "$PPPOE_ENABLED" 8)
OVERHEAD_PER_FRAME=$((38 + VLAN_BYTES + PPPOE_BYTES))

export ONT_HOST ONT_USER ONT_PASS

# ------------------------------------------------------------------------------
# 1. Execute expect & parse the stats
# ------------------------------------------------------------------------------
RAW_OUTPUT=$(expect "$EXPECT_SCRIPT" 2>&1)
EXPECT_EXIT_CODE=$?

if [ "$EXPECT_EXIT_CODE" -ne 0 ]; then
    log "ERROR" "Expect script failed with exit code $EXPECT_EXIT_CODE"
    exit 1
fi

PARSED_JSON=$(printf '%s\n' "$RAW_OUTPUT" | awk -v wan="$WAN_INTERFACE" '
    index($0, wan " packet statistic:") > 0 { found=1; in_wan=1; next }
    /-----------------------------------------/ { if (in_wan) in_wan=0 }
    in_wan && /^[ \t]*BytesSent[ \t]*:/ { split($0, a, ":"); bytes_sent=a[2]; gsub(/[ \t\r\n]/, "", bytes_sent) }
    in_wan && /^[ \t]*BytesReceived[ \t]*:/ { split($0, b, ":"); bytes_recv=b[2]; gsub(/[ \t\r\n]/, "", bytes_recv) }
    in_wan && /^[ \t]*FrameSent[ \t]*:/ { split($0, f, ":"); frames_sent=f[2]; gsub(/[ \t\r\n]/, "", frames_sent) }
    in_wan && /^[ \t]*FrameReceived[ \t]*:/ { split($0, g, ":"); frames_recv=g[2]; gsub(/[ \t\r\n]/, "", frames_recv) }
    END { if (found) printf "{\"bytes_sent\":%d,\"bytes_received\":%d,\"frames_sent\":%d,\"frames_received\":%d}\n", bytes_sent+0, bytes_recv+0, frames_sent+0, frames_recv+0 }
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
    local raw="$1" frames="$2"
    local net=$((raw - frames * OVERHEAD_PER_FRAME))
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
    local entity="$1" state="$2" name="$3" raw="$4" frames="$5"
    local http_code
    http_code=$(curl -sS -k -m 20 --retry 3 --retry-delay 2 --retry-all-errors \
        -o /dev/null -w '%{http_code}' -X POST \
        -H "Authorization: Bearer ${HA_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{
            \"state\": \"${state}\",
            \"attributes\": {
              \"unit_of_measurement\": \"B\",
              \"device_class\": \"data_size\",
              \"state_class\": \"total_increasing\",
              \"friendly_name\": \"${name}\",
              \"raw_bytes\": ${raw},
              \"frames\": ${frames},
              \"overhead_per_frame\": ${OVERHEAD_PER_FRAME}
            }
          }" \
        "${HA_SCHEME}://${HA_IP}:${HA_PORT}/api/states/${entity}") || {
        log "ERROR" "Failed to reach Home Assistant while pushing ${entity}"
        return 1
    }

    case "$http_code" in
        2??) return 0 ;;
        *)   log "ERROR" "Home Assistant returned HTTP ${http_code} for ${entity}"; return 1 ;;
    esac
}

FAILURES=0
push_state "sensor.huawei_ont_bytes_received" "$NET_RECV" "Huawei ONT Download Bytes" "$BYTES_RECV" "$FRAMES_RECV" || FAILURES=$((FAILURES + 1))
push_state "sensor.huawei_ont_bytes_sent"     "$NET_SENT" "Huawei ONT Upload Bytes"     "$BYTES_SENT" "$FRAMES_SENT" || FAILURES=$((FAILURES + 1))
push_state "sensor.huawei_ont_bytes_total"     "$NET_TOTAL" "Huawei ONT Total Bytes"      "$RAW_TOTAL" "$FRAMES_TOTAL" || FAILURES=$((FAILURES + 1))

if [ "$FAILURES" -eq 0 ]; then
    log "INFO" "Successfully pushed Huawei ONT stats to Home Assistant."
else
    log "ERROR" "$FAILURES of 3 sensor updates failed."
    exit 1
fi
