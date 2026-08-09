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
# The WAP shell sometimes drops input typed right at the prompt boundary, so
# the command is (re)sent until stats come back. Number of attempts.
: "${COMMAND_ATTEMPTS:=3}"
# The ONT allows a single SSH session and holds it for a while after quit, so
# a new login may hit "The number of sessions exceeds...". When set, the
# exporter answers the prompt to remove the listed stale session automatically.
: "${AUTO_KILL_SESSIONS:=true}"

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
    # Wait for the WAP> prompt before typing (early input is silently dropped).
    # If the ONT reports too many SSH sessions, remove the listed stale
    # session so the new login can proceed.
    ELAPSED=0
    while [ "$ELAPSED" -lt "$PROMPT_TIMEOUT" ]; do
        grep -q 'WAP>' "$OUT_FILE" 2>/dev/null && break
        if grep -q 'Enter the ID of the session to be removed:' "$OUT_FILE" 2>/dev/null; then
            if [ "$AUTO_KILL_SESSIONS" = "true" ]; then
                ID=$(sed -n 's/^ *\([0-9]\+\)\. ssh.*/\1/p' "$OUT_FILE" | head -1)
                if [ -n "$ID" ]; then
                    printf '%s\r' "$ID"
                    sleep 3
                fi
            else
                printf '\003'    # Ctrl-C: abort the login instead of removing
                break
            fi
        fi
        sleep 0.5
        ELAPSED=$((ELAPSED + 1))
    done
    grep -q 'WAP>' "$OUT_FILE" 2>/dev/null || exit 1

    printf 'display bbsp stats wan\r'
    ATTEMPT=1
    while [ "$ATTEMPT" -lt "$COMMAND_ATTEMPTS" ]; do
        sleep 2
        grep -q 'packet statistic' "$OUT_FILE" 2>/dev/null && break
        printf 'display bbsp stats wan\r'
        ATTEMPT=$((ATTEMPT + 1))
    done

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
echo "=== FAILURE SESSION LOG START ==="
cat "$OUT_FILE"
echo "=== FAILURE SESSION LOG END ==="
exit 1
