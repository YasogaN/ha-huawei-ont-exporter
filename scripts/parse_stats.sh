#!/bin/sh

# ==============================================================================
# Pure, side-effect-free helpers for parsing `display bbsp stats wan` output and
# computing overhead-adjusted byte counters.
#
# Sourced by main.sh (the exporter) and test.sh (the unit tests) so both always
# exercise the exact same logic. No script-local state is required beyond the
# function arguments.
# ==============================================================================

# parse_stats <wan> : read the ONT's raw WAP output on stdin and print a JSON
# object with the four counters (bytes_sent, bytes_received, frames_sent,
# frames_received) for the requested WAN interface. Prints nothing when the
# interface is absent from the output (the caller treats that as an error).
parse_stats() {
    wan="$1"
    awk -v wan="$wan" '
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
    '
}

# deduct_overhead <raw_bytes> <frames> <overhead_per_frame> : subtract the
# per-frame wire overhead from a raw byte counter. Clamped to 0: a negative
# result only means the counters were reset between samples, never a real
# negative byte count. Requires a `log <level> <message>` function to exist
# (provided by main.sh and test.sh).
deduct_overhead() {
    raw="$1"
    frames="$2"
    overhead="$3"
    net=$((raw - frames * overhead))
    if [ "$net" -lt 0 ]; then
        log "WARN" "Overhead deduction produced a negative value (raw=$raw frames=$frames); clamping to 0"
        net=0
    fi
    echo "$net"
}

# sensor_payload <state> <name> <raw_bytes> <frames> <overhead_per_frame> :
# build the exact JSON body pushed to the Home Assistant REST API. Every sensor
# shares the same attribute shape; the total sensor just passes the summed raw
# counters and frame counts (never re-derived separately), so this stays in one
# place.
sensor_payload() {
    state="$1"
    name="$2"
    raw="$3"
    frames="$4"
    overhead="$5"
    printf '{"state":"%s","attributes":{"unit_of_measurement":"B","device_class":"data_size","state_class":"total_increasing","friendly_name":"%s","raw_bytes":%s,"frames":%s,"overhead_per_frame":%d}}' \
        "$state" "$name" "$raw" "$frames" "$overhead"
}
