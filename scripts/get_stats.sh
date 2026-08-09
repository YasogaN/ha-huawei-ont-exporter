#!/bin/sh

# ==============================================================================
# Huawei ONT stats collector (dbclient)
# Connects over SSH non-interactively and runs: display bbsp stats wan
# Credentials are read from the environment (ONT_HOST / ONT_USER / ONT_PASS).
#
# The ONT's WAP shell does NOT accept a remote command (its Dropbear resets on
# the SSH exec request), so the command is typed into the interactive session.
# dbclient authenticates with the password from DROPBEAR_PASSWORD and runs the
# session without a pty (-T), which the WAP shell accepts in line mode. A
# feeder watches the session output and types the command and quit at the right
# moments instead of relying on fixed sleeps.
#
# Teardown: the feeder always sends `quit` (even if the session never reached
# the WAP> prompt) so the WAP shell exits and the ONT's single session slot is
# freed promptly. dbclient runs directly (no `timeout` wrapper: busybox timeout
# does not forward signals to its child, so killing it would orphan the SSH
# session). A watcher force-terminates the connection after CLOSE_GRACE seconds
# if the remote has not closed on its own, and the EXIT trap cleans up every
# child process even when the script is interrupted.
# ==============================================================================

set -u

# Load all configuration (defaults, validation, normalization) from config.sh
# shellcheck disable=SC1091  # config.sh is linted separately (scripts/*.sh)
. "$(dirname "$0")/config.sh"

require ONT_HOST ONT_USER ONT_PASS

WORKDIR=$(mktemp -d)
OUT_FILE="$WORKDIR/session.log"
CMD_FIFO="$WORKDIR/cmd.fifo"
mkfifo "$CMD_FIFO"

SESSION_PID=
FEEDER_PID=
WATCHER_PID=

# Invoked via trap on EXIT/INT/TERM, which shellcheck does not track.
# shellcheck disable=SC2329
cleanup() {
    # Tear down any children still running: stop the feeder first so the fifo
    # write end closes (dbclient sees EOF on stdin), then the session itself.
    kill "$FEEDER_PID" 2>/dev/null
    wait "$FEEDER_PID" 2>/dev/null
    kill "$WATCHER_PID" 2>/dev/null
    wait "$WATCHER_PID" 2>/dev/null
    kill "$SESSION_PID" 2>/dev/null
    wait "$SESSION_PID" 2>/dev/null
    rm -rf "$WORKDIR"
}
trap cleanup EXIT
trap 'cleanup; exit 1' INT TERM

# SSH session: commands arrive via the fifo, all output goes to OUT_FILE.
# Run dbclient directly so teardown can signal the real SSH process.
env DROPBEAR_PASSWORD="$ONT_PASS" \
    dbclient -y -y -T "$ONT_USER@$ONT_HOST" \
    < "$CMD_FIFO" > "$OUT_FILE" 2>&1 &
SESSION_PID=$!

# Feeder: watches the session output and sends input at the right moment.
# Holds the fifo open for the whole session so dbclient never sees early EOF.
(
    PROMPT_SEEN=0

    # Wait for the WAP> prompt before typing (early input is silently dropped).
    # If the ONT reports too many SSH sessions, remove the listed stale session
    # so the new login can proceed.
    ELAPSED=0
    while [ "$ELAPSED" -lt "$PROMPT_TIMEOUT" ]; do
        if grep -q 'WAP>' "$OUT_FILE" 2>/dev/null; then
            PROMPT_SEEN=1
            break
        fi
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
        ELAPSED=$((ELAPSED + 2))
    done

    if [ "$PROMPT_SEEN" -eq 1 ]; then
        # Send the command, re-sending until stats come back
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
            ELAPSED=$((ELAPSED + 2))
        done
    fi

    # Close the WAP shell so the ONT frees its single session slot promptly.
    # Best effort: sent even if the prompt never appeared.
    printf 'quit\r'
    sleep 1
) > "$CMD_FIFO" &
FEEDER_PID=$!

# Let the feeder finish (all input sent, including `quit`).
wait "$FEEDER_PID" 2>/dev/null

# Give the remote a short window to close after `quit`; force-close the
# connection afterwards so no session lingers on the ONT.
(
    sleep "$CLOSE_GRACE"
    kill "$SESSION_PID" 2>/dev/null
) &
WATCHER_PID=$!
wait "$SESSION_PID" 2>/dev/null
kill "$WATCHER_PID" 2>/dev/null
wait "$WATCHER_PID" 2>/dev/null

# dbclient exits non-zero even on a clean session close, so judge success by
# whether the command output actually came back.
if grep -q 'packet statistic' "$OUT_FILE"; then
    cat "$OUT_FILE"
    exit 0
fi
echo "=== FAILURE SESSION LOG START ==="
cat "$OUT_FILE"
echo "=== FAILURE SESSION LOG END ==="
exit 1
