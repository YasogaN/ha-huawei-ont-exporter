#!/bin/sh

# ==============================================================================
# Unit tests for the risky pure logic: the awk parser for `display bbsp stats
# wan` output and the per-frame overhead deduction, plus a golden-file check on
# the total sensor's attribute payload (so its exact shape cannot drift
# unnoticed).
#
# Run with: make test   (or directly: ./scripts/test.sh)
# ==============================================================================

set -eu

cd "$(dirname "$0")/.." || exit 1

# shellcheck disable=SC1091  # parse_stats.sh is linted separately (scripts/*.sh)
. ./scripts/parse_stats.sh

# The real `log` lives in main.sh; stub it here (the clamping path logs a WARN).
log() {
    echo "[test] [$1] $2" >&2
}

PASS=0
FAIL=0

assert_eq() {
    label="$1"
    expected="$2"
    actual="$3"
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS + 1))
        echo "ok   - $label"
    else
        FAIL=$((FAIL + 1))
        echo "FAIL - $label"
        echo "  expected: $expected"
        echo "  actual:   $actual"
    fi
}

# Realistic `display bbsp stats wan` capture from a Huawei HG8245H5 (see the
# README's "Example ONT output"): wan2/wan1/wan3 blocks with the login banner
# and session teardown text the parser has to wade through.
SAMPLE_CAPTURE=$(cat <<'EOF'
ssh -o HostKeyAlgorithms=ssh-rsa -o PubkeyAcceptedAlgorithms=ssh-rsa root@192.168.1.1
root@192.168.1.1's password:

Password is default value, please modify it!
WAP>display bbsp stats wan
-----------------------------------------
wan2 packet statistic:
    WAN Status              : Connected
    BytesSent               : 758
    BytesReceived           : 215266
    FrameSent               : 11
    FrameReceived           : 2909
    UnicastFrameSent        : 0
    UnicastFrameReceived    : 0
    MulticastFrameSent      : 11
    MulticastFrameReceived  : 0
    BroadcastFrameSent      : 0
    BroadcastFrameReceived  : 2909
-----------------------------------------

-----------------------------------------
wan1 packet statistic:
    WAN Status              : Connected
    BytesSent               : 210288653
    BytesReceived           : 173073983
    FrameSent               : 233426
    FrameReceived           : 290663
    UnicastFrameSent        : 233425
    UnicastFrameReceived    : 290663
    MulticastFrameSent      : 0
    MulticastFrameReceived  : 0
    BroadcastFrameSent      : 1
    BroadcastFrameReceived  : 0
-----------------------------------------

-----------------------------------------
wan3 packet statistic:
    WAN Status              : Connected
    BytesSent               : 3545
    BytesReceived           : 4090140
    FrameSent               : 8
    FrameReceived           : 56653
    UnicastFrameSent        : 5
    UnicastFrameReceived    : 17778
    MulticastFrameSent      : 0
    MulticastFrameReceived  : 0
    BroadcastFrameSent      : 3
    BroadcastFrameReceived  : 38875
-----------------------------------------

success!
WAP>quit
success!
WAP>
Configuration console exit, please retry to log on
Connection to 192.168.1.1 closed.
EOF
)

# --- awk parser -------------------------------------------------------------

parse_json() {
    printf '%s\n' "$SAMPLE_CAPTURE" | parse_stats "$1"
}

assert_eq "parse wan1 (the real WAN interface)" \
    '{"bytes_sent":210288653,"bytes_received":173073983,"frames_sent":233426,"frames_received":290663}' \
    "$(parse_json wan1)"

assert_eq "parse wan2" \
    '{"bytes_sent":758,"bytes_received":215266,"frames_sent":11,"frames_received":2909}' \
    "$(parse_json wan2)"

assert_eq "parse wan3" \
    '{"bytes_sent":3545,"bytes_received":4090140,"frames_sent":8,"frames_received":56653}' \
    "$(parse_json wan3)"

assert_eq "parse unknown interface emits nothing" \
    "" \
    "$(parse_json wan9)"

# A WAN that exists but has no traffic yet: block with no Frame* counters at all
# (e.g. Disconnected). Missing counters must default to 0, not stay empty.
PARTIAL_CAPTURE=$(cat <<'EOF'
WAP>display bbsp stats wan
-----------------------------------------
wan1 packet statistic:
    WAN Status              : Disconnected
    BytesSent               : 1234
    BytesReceived           : 5678
-----------------------------------------
success!
EOF
)

assert_eq "disconnected/partial block defaults missing counters to 0" \
    '{"bytes_sent":1234,"bytes_received":5678,"frames_sent":0,"frames_received":0}' \
    "$(printf '%s\n' "$PARTIAL_CAPTURE" | parse_stats wan1)"

# Some devices send CRLF line endings; awk splits on LF, leaving \r at the end
# of every line. The parser must tolerate that (values are scrubbed, headers
# are substring-matched).
CRLF_CAPTURE=$(printf '%s\r\n%s\r\n%s\r\n%s\r\n%s\r\n%s\r\n%s\r\n%s\r\n' \
    'WAP>display bbsp stats wan' \
    '-----------------------------------------' \
    'wan1 packet statistic:' \
    '    WAN Status              : Connected' \
    '    BytesSent               : 1234' \
    '    BytesReceived           : 5678' \
    '-----------------------------------------' \
    'success!')

assert_eq "CRLF line endings parse identically" \
    '{"bytes_sent":1234,"bytes_received":5678,"frames_sent":0,"frames_received":0}' \
    "$(printf '%s\n' "$CRLF_CAPTURE" | parse_stats wan1)"

# --- overhead deduction -----------------------------------------------------

# Default config: VLAN on (4 B) + PPPoE off (0 B) => 38 + 4 + 0 = 42 B/frame.
OVERHEAD=42

assert_eq "wan1 sent raw - frames*overhead" "200484761" \
    "$(deduct_overhead 210288653 233426 "$OVERHEAD")"
assert_eq "wan1 recv raw - frames*overhead" "160866137" \
    "$(deduct_overhead 173073983 290663 "$OVERHEAD")"
assert_eq "wan2 sent raw - frames*overhead" "296" \
    "$(deduct_overhead 758 11 "$OVERHEAD")"
assert_eq "wan2 recv raw - frames*overhead" "93088" \
    "$(deduct_overhead 215266 2909 "$OVERHEAD")"
assert_eq "wan3 sent raw - frames*overhead" "3209" \
    "$(deduct_overhead 3545 8 "$OVERHEAD")"
assert_eq "wan3 recv raw - frames*overhead" "1710714" \
    "$(deduct_overhead 4090140 56653 "$OVERHEAD")"

# Negative result (counters reset between samples) clamps to 0.
assert_eq "negative deduction clamps to 0" "0" \
    "$(deduct_overhead 10 100 "$OVERHEAD" 2>/dev/null)"

# PPPoE on (+8 B/frame) => 50 B/frame.
assert_eq "pppoe overhead (50 B/frame)" "198617353" \
    "$(deduct_overhead 210288653 233426 50)"

# README-scale counters (>2^31): this only works if the shell arithmetic is
# 64-bit, which the alpine image provides (amd64/arm64). The expected values are
# the exact ones printed in the README's log sample, so a doc drift also fails.
assert_eq "large counters (README-scale) sent" "145627052543" \
    "$(deduct_overhead 152042884343 152757900 "$OVERHEAD")"
assert_eq "large counters (README-scale) recv" "154769166150" \
    "$(deduct_overhead 162439892682 182636346 "$OVERHEAD")"

# --- total sensor golden payload -------------------------------------------

# The total sensor's state is the sum of the (deducted) directions and its
# attributes are the sums of the raw counters / frame counts. Freeze that exact
# payload shape in a golden file so it cannot drift. Regenerate with:
#   rm scripts/testdata/total_payload.golden && ./scripts/test.sh
NET_TOTAL=$(( $(deduct_overhead 210288653 233426 "$OVERHEAD") + $(deduct_overhead 173073983 290663 "$OVERHEAD") ))
RAW_TOTAL=$((210288653 + 173073983))
FRAMES_TOTAL=$((233426 + 290663))
TOTAL_PAYLOAD=$(sensor_payload "$NET_TOTAL" "Huawei ONT Total Bytes" "$RAW_TOTAL" "$FRAMES_TOTAL" "$OVERHEAD")

GOLDEN=./scripts/testdata/total_payload.golden
if [ -f "$GOLDEN" ]; then
    assert_eq "total sensor payload matches golden file" "$(cat "$GOLDEN")" "$TOTAL_PAYLOAD"
else
    printf '%s\n' "$TOTAL_PAYLOAD" > "$GOLDEN"
    echo "note - golden file missing; wrote $GOLDEN (commit it)"
fi

# --- config.sh scheme validation -------------------------------------------

# config_error exits, so run config.sh in a subshell and capture its exit code.
# The `if !` guard keeps `set -e` from aborting before the result is echoed.
scheme_exit_code() {
    if ! ( HA_SCHEME="$1"; . ./scripts/config.sh ) >/dev/null 2>&1; then
        echo 1
    else
        echo 0
    fi
}

assert_eq "scheme http accepted" "0" "$(scheme_exit_code http)"
assert_eq "scheme https accepted" "0" "$(scheme_exit_code https)"
assert_eq "scheme HTTPS normalized to lowercase" "0" "$(scheme_exit_code HTTPS)"
assert_eq "scheme ftp rejected" "1" "$(scheme_exit_code ftp)"
# `: "${HA_SCHEME:=http}"` defaults empty values, so '' is valid (becomes http).
assert_eq "scheme empty defaults to http" "0" "$(scheme_exit_code '')"

echo
if [ "$FAIL" -eq 0 ]; then
    echo "All $PASS tests passed."
    exit 0
fi
echo "$FAIL of $((PASS + FAIL)) tests FAILED."
exit 1
