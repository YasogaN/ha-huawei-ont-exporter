#!/bin/sh

# ==============================================================================
# Huawei ONT stats collector (sshpass)
# Connects over SSH non-interactively and runs: display bbsp stats wan
# Credentials are read from the environment (ONT_HOST / ONT_USER / ONT_PASS).
#
# The ONT's WAP shell does NOT accept a remote command (its Dropbear resets on
# the SSH exec request), so we drive it interactively through a pty. Instead of
# blind sleeps, the session output is watched: we only type the command once
# the WAP> prompt has appeared, and only quit once the output has finished
# ("success!" is printed by the ONT after the stats).
# ==============================================================================

set -u

: "${ONT_HOST:?ONT_HOST is required}"
: "${ONT_USER:?ONT_USER is required}"
: "${ONT_PASS:?ONT_PASS is required}"

# Timeouts in seconds before giving up (should be plenty; the ONT responds
# within a second on healthy firmware). Configurable via the environment.
: "${PROMPT_TIMEOUT:=15}"
: "${OUTPUT_TIMEOUT:=20}"

WORKDIR=$(mktemp -d)
OUT_FILE="$WORKDIR/session.log"
CMD_FIFO="$WORKDIR/cmd.fifo"
mkfifo "$CMD_FIFO"
trap 'rm -rf "$WORKDIR"' EXIT

# SSH session: commands arrive via the fifo, all output goes to OUT_FILE
timeout 45 env SSHPASS="$ONT_PASS" sshpass -e ssh -tt \
    -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -o HostKeyAlgorithms=+ssh-rsa \
    -o PubkeyAcceptedKeyTypes=+ssh-rsa \
    "$ONT_USER@$ONT_HOST" < "$CMD_FIFO" > "$OUT_FILE" 2>&1 &
SSH_PID=$!

# Feeder: watches the session output and sends commands at the right moment.
# Holds the fifo open for the whole session so ssh never sees an early EOF.
(
    # Wait for the WAP> prompt before typing (early input is silently dropped)
    ELAPSED=0
    while [ "$ELAPSED" -lt "$PROMPT_TIMEOUT" ] && ! grep -q 'WAP>' "$OUT_FILE" 2>/dev/null; do
        sleep 0.5
        ELAPSED=$((ELAPSED + 1))
    done
    grep -q 'WAP>' "$OUT_FILE" 2>/dev/null || exit 1

    printf 'display bbsp stats wan\r'

    # Wait for the command output to complete (ONT prints "success!" after it)
    ELAPSED=0
    while [ "$ELAPSED" -lt "$OUTPUT_TIMEOUT" ] && ! grep -q 'success!' "$OUT_FILE" 2>/dev/null; do
        sleep 0.5
        ELAPSED=$((ELAPSED + 1))
    done

    printf 'quit\r'
    sleep 1
) > "$CMD_FIFO" &
FEEDER_PID=$!

wait "$SSH_PID"
kill "$FEEDER_PID" 2>/dev/null
wait "$FEEDER_PID" 2>/dev/null

# The ONT's Dropbear exits non-zero even on a clean session close, so judge
# success by whether the command output actually came back.
if grep -q 'packet statistic' "$OUT_FILE"; then
    cat "$OUT_FILE"
    exit 0
fi
exit 1
