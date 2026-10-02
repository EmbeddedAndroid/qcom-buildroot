#!/usr/bin/env bash
# qcom/lava/connect.sh: reserve a LAVA board, flash it from inside the
# device-attached container, and drop you on its serial console. The
# interactive counterpart of submit.sh.
#
# A flash-only job (submit.sh) releases the board when it finishes, so you can
# never log in to the board it flashed. Here the flash happens inside a LAVA
# MCP board session, which keeps the board reserved: a container next to the
# board with its USB and serial mapped in. The flash tarball is staged into
# that container and written with qdl, then the board's UART is attached. The
# board is held until you leave the console, then released.
#
#   1. open_board_session(<device_type>, console=true, downloads=[tarball]):
#      reserve a board and a container, stage the tarball at /lava-downloads.
#   2. run_device_command qdl_enter: put the board in EDL.
#   3. run_in_session "tar -xzf ... && qdl ...": flash over USB. The device
#      type, qdl storage, firehose, rawprogram/patch lists and any nested
#      `path:` come from the same job YAML submit.sh submits.
#   4. attach_console: ssh -W to the board's UART through the gateway, run
#      under socat for a raw tty.
#   5. on exit, close_board_session releases the board.
#
# The interactive session needs a board whose device dictionary allows the
# serial-console proxy (allow_test_services) and that is tagged for remote
# access; connect.sh stops before uploading when no board of the type does.
#
# Needs curl, jq, ssh, websocat (fetched to ~/.local/bin if missing) and,
# for a raw tty, socat.
#
# Usage:
#   connect.sh <tarball> <job-yaml> [<get_url> <artifact_token>]
# Without a URL and token it uploads the tarball itself.
#
# Based on lemans/lava/connect.sh by Jorge Ramirez-Ortiz.
set -euo pipefail

TARBALL="${1:?usage: connect.sh <tarball> <job-yaml> [<get_url> <artifact_token>]}"
JOB_YAML="${2:?usage: connect.sh <tarball> <job-yaml> [<get_url> <artifact_token>]}"
GET_URL="${3:-}"
UP_TOK="${4:-}"

# A full Yocto flash runs well past run_in_session's 120 s default.
FLASH_TIMEOUT="${FLASH_LAVA_FLASH_TIMEOUT:-1200}"
CONNECT_MAX="${FLASH_LAVA_CONNECT_MAX:-24}"   # 24 * 10 s for the session to connect
MCP_MAX_TIME=$((FLASH_TIMEOUT+120))

[ -f "$TARBALL" ]  || { echo "ERROR: tarball not found: $TARBALL"  >&2; exit 1; }
[ -f "$JOB_YAML" ] || { echo "ERROR: job yaml not found: $JOB_YAML" >&2; exit 1; }
command -v curl   >/dev/null || { echo "ERROR: 'curl' not found" >&2; exit 1; }
command -v jq     >/dev/null || { echo "ERROR: 'jq' not found" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
. "$(dirname "$0")/lib.sh"

TOK="$(lava_token)"
[ -n "$TOK" ] || { echo "ERROR: no LAVA token (set \$LAVA_TOKEN or add a lava MCP X-Lava-Token to $CLAUDE_JSON)" >&2; exit 1; }

# --- qdl arguments and device type from the job YAML ----------------------------
DEVICE_TYPE="${FLASH_LAVA_DEVICE_TYPE:-$(yaml_val device_type)}"
STORAGE="$(yaml_val storage)"
FIREHOSE="$(yaml_val firehose_program)"; FIREHOSE="${FIREHOSE:-prog_firehose_ddr.elf}"
RAWPROGRAM="$(yaml_val rawprogram)"
PATCH="$(yaml_val patch)"
SUBPATH="$(yaml_val path)"   # empty for the flat `make` tarballs
[ -n "$DEVICE_TYPE" ] || { echo "ERROR: no 'device_type:' found in $JOB_YAML" >&2; exit 1; }
[ -n "$RAWPROGRAM" ] || { echo "ERROR: no 'rawprogram:' found in $JOB_YAML" >&2; exit 1; }
QDL_ARGS="--debug${STORAGE:+ --storage $STORAGE} $FIREHOSE $RAWPROGRAM $PATCH"

FN="$(basename "$TARBALL")"

# --- 0. a board that can host the session ---------------------------------------
echo ">> looking for a $DEVICE_TYPE board that allows the serial-console proxy ..."
BOARD="$(console_board "$DEVICE_TYPE")"
if [ -z "$BOARD" ]; then
  echo "ERROR: no $DEVICE_TYPE board in Good health allows the serial-console proxy" >&2
  echo "       (allow_test_services), which the interactive session needs. Use the" >&2
  echo "       flash-only mode (FLASH_LAVA_CONNECT=0) or ask a lab admin to enable it." >&2
  exit 1
fi
echo "   $BOARD can host it."

# --- upload the tarball if submit.sh did not hand us a URL ----------------------
if [ -z "$GET_URL" ] || [ -z "$UP_TOK" ]; then
  lava_upload "$TARBALL"
fi

# --- tools: websocat (required) and socat (raw tty) -----------------------------
export PATH="$HOME/.local/bin:$PATH"
# A websocat that does not run (another architecture's build) is replaced.
if ! websocat --version >/dev/null 2>&1; then
  ARCH="$(uname -m)"
  echo ">> no working websocat: fetching the $ARCH static binary to ~/.local/bin ..."
  mkdir -p "$HOME/.local/bin"
  WURL=""
  command -v gh >/dev/null && WURL="$(gh api repos/vi/websocat/releases/latest \
    --jq ".assets[] | select(.name|test(\"$ARCH-unknown-linux-musl\$\")) | .browser_download_url" 2>/dev/null | head -1)"
  [ -n "$WURL" ] || WURL="https://github.com/vi/websocat/releases/download/v1.14.1/websocat.$ARCH-unknown-linux-musl"
  curl -fsSL "$WURL" -o "$HOME/.local/bin/websocat" && chmod +x "$HOME/.local/bin/websocat" \
    || { echo "ERROR: could not install websocat (needed for the SSH gateway tunnel). Install it manually." >&2; exit 1; }
  echo "   installed $(websocat --version 2>/dev/null || echo websocat)"
fi

# --- 1. open the board session (container + console) with the tarball staged ----
echo ">> [1/4] opening an interactive $DEVICE_TYPE session (console + staged tarball) ..."
# The newest job id before opening tells our session apart from stale ones.
PREOPEN="$(mcp list_board_sessions '{}')"
sessions_field() {
  printf '%s' "$1" | jq -rs "[ .[] | (if type==\"array\" then .[] else . end) ] | $2" 2>/dev/null || true
}
PREMAX="$(sessions_field "$PREOPEN" 'map(.job_id // 0) | max // 0')"; PREMAX="${PREMAX:-0}"

# downloads stages the tarball at /lava-downloads: the container cannot fetch
# the token-guarded URL itself.
OPEN_ARGS="$(jq -nc --arg dt "$DEVICE_TYPE" --arg u "$GET_URL" --arg a "$UP_TOK" \
  '{device_type:$dt, console:true, wait_seconds:90, downloads:[{url:$u, headers:{Authorization:$a}}]}')"
OPEN="$(mcp open_board_session "$OPEN_ARGS")"
SESSION_ID="$(jq_field "$OPEN" '.session_id // empty')"
CONSOLE_ID="$(jq_field "$OPEN" '.console_session_id // empty')"
JOB_ID="$(jq_field "$OPEN" '.job_id // empty')"

# If open returned nothing parseable, recover the ids from list_board_sessions:
# ours is the job newer than the pre-open maximum.
if [ -z "$SESSION_ID" ]; then
  echo "   open returned no ids; recovering via list_board_sessions ..."
  for _ in $(seq 1 12); do
    LST="$(mcp list_board_sessions '{}')"
    JOB_ID="$(sessions_field "$LST" "map(.job_id // 0) | map(select(. > $PREMAX)) | max // empty")"
    if [ -n "$JOB_ID" ]; then
      SESSION_ID="$(sessions_field "$LST" "map(select(.kind==\"container\" and .job_id==$JOB_ID)) | last.session_id // empty")"
      CONSOLE_ID="$(sessions_field "$LST" "map(select(.kind==\"console\"   and .job_id==$JOB_ID)) | last.session_id // empty")"
    fi
    [ -n "$SESSION_ID" ] && [ -n "$CONSOLE_ID" ] && break
    sleep 5
  done
fi
[ -n "$SESSION_ID" ] || { echo "ERROR: could not find a board session (open_board_session failed? check the X-Lava-Token header)" >&2; exit 1; }
echo "   container session $SESSION_ID  console ${CONSOLE_ID:-<none>}  job ${JOB_ID:-?}"

# --- release the board on any exit ----------------------------------------------
cleanup() {
  echo ""
  echo ">> closing board session $SESSION_ID (releasing the board) ..."
  mcp close_board_session "$(jq -nc --arg s "$SESSION_ID" '{session_id:$s}')" >/dev/null 2>&1 || \
    echo "   WARNING: close failed: release it with close_board_session($SESSION_ID) or cancel job ${JOB_ID:-?}"
  rm -rf "$TMP"
}
trap cleanup EXIT

# --- wait for the container to connect to the gateway ---------------------------
connected=0
[ "$(jq_field "$OPEN" '.connected // empty')" = "true" ] && connected=1
if [ "$connected" = 0 ]; then
  echo ">> waiting for the session container to connect ..."
  for _ in $(seq 1 "$CONNECT_MAX"); do
    LST="$(mcp list_board_sessions '{}')"
    st="$(sessions_field "$LST" "map(select(.session_id==\"$SESSION_ID\")) | last.status // empty")"
    [ "$st" = "connected" ] && { connected=1; break; }
    sleep 10
  done
fi
[ "$connected" = 1 ] || { echo "ERROR: session $SESSION_ID did not connect in time" >&2; exit 1; }
echo "   connected."

# The scheduler picks any board of the type that may host a session; flash
# only the one checked for the console proxy.
ON="$(jq_field "$(mcp get_job "$(jq -nc --argjson j "${JOB_ID:-0}" '{job_id:$j}')")" '.actual_device // empty')"
[ "$ON" = "$BOARD" ] || { echo "ERROR: session job ${JOB_ID:-?} runs on ${ON:-an unknown board}, not $BOARD" >&2; exit 1; }
echo "   on $BOARD."

# --- 2. put the board in EDL ----------------------------------------------------
# The device's qdl_enter user command (tac-api bootToEDL on lemans-evk and
# monaco-arduino-monza); FLASH_LAVA_EDL_CMD overrides the name.
EDL_CMD="${FLASH_LAVA_EDL_CMD:-qdl_enter}"
echo ">> [2/4] forcing the board into EDL ($EDL_CMD) ..."
EDL="$(mcp run_device_command "$(jq -nc --arg s "$SESSION_ID" --arg n "$EDL_CMD" '{session_id:$s,name:$n}')")"
echo "   $EDL_CMD: ok=$(jq_field "$EDL" '.ok') rc=$(jq_field "$EDL" '.exit_status')"
sleep 8

# --- 3. flash from inside the container -----------------------------------------
# The script travels base64-encoded as one argument; QDL_EXIT=<rc> carries
# qdl's exit code back in the output.
CDPATH_CMD=""; [ -n "$SUBPATH" ] && CDPATH_CMD="cd '$SUBPATH' && "
FLASH_SCRIPT="echo '--- waiting for EDL (05c6:9008) ---'
for i in \$(seq 1 30); do lsusb | grep -q 05c6:9008 && break; sleep 2; done
lsusb | grep 05c6 || true
cd /lava-downloads && tar -xzf '$FN' && ${CDPATH_CMD}qdl $QDL_ARGS
echo QDL_EXIT=\$?"
FLASH_B64="$(printf '%s' "$FLASH_SCRIPT" | base64 -w0)"
RUN_CMD="echo $FLASH_B64 | base64 -d | bash"
echo ">> [3/4] flashing in-container (timeout ${FLASH_TIMEOUT}s) ..."
echo "   qdl $QDL_ARGS${SUBPATH:+   (path: $SUBPATH)}"
FLASH_OUT="$(mcp run_in_session "$(jq -nc --arg s "$SESSION_ID" --argjson t "$FLASH_TIMEOUT" --arg c "$RUN_CMD" '{session_id:$s,timeout:$t,command:$c}')")"
FLASH_TXT="$(jq_field "$FLASH_OUT" '.output // .stdout // .')"
printf '%s\n' "$FLASH_TXT" | tail -30
# The sentinel wins: run_in_session sometimes returns a truncated body after a
# complete flash. Then the tool's exit_status; no output at all means the
# flash never ran.
RC="$(printf '%s' "$FLASH_TXT" | sed -n 's/.*QDL_EXIT=\([0-9][0-9]*\).*/\1/p' | tail -1)"
[ -n "$RC" ] || RC="$(jq_field "$FLASH_OUT" '.exit_status // empty')"
if [ -z "$RC" ]; then
  if [ -z "$FLASH_TXT" ] || [ "$FLASH_TXT" = null ]; then
    echo "ERROR: in-container flash produced no output: the board likely never entered EDL (check '$EDL_CMD')." >&2
  else
    echo "ERROR: could not determine the flash result (no QDL_EXIT sentinel and no exit_status); see output above." >&2
  fi
  exit 1
fi
if [ "$RC" != 0 ]; then
  echo "ERROR: in-container qdl exited $RC (see output above; wrong path:/firehose, or board not in EDL)." >&2
  exit 1
fi
echo "   flash complete."

# --- 4. attach to the board's serial console ------------------------------------
[ -n "$CONSOLE_ID" ] || { echo "ERROR: no console session was opened; cannot attach to the UART" >&2; exit 1; }
echo ">> [4/4] attaching to the board console ($CONSOLE_ID) ..."
AC="$(mcp attach_console "$(jq -nc --arg s "$CONSOLE_ID" '{session_id:$s}')")"
SSH_W="$(jq_field "$AC" '.ssh_W_command')"
[ -n "$SSH_W" ] && [ "$SSH_W" != null ] || { echo "ERROR: attach_console returned no ssh command: $(jq_field "$AC" '.console_note // .error // .')" >&2; exit 1; }
KEY="$TMP/console.key"
jq_field "$AC" '.private_key' > "$KEY"; chmod 600 "$KEY"
# Point the returned command at the key just written.
SSH_W_LOCAL="$(printf '%s' "$SSH_W" | sed -E "s#-i [^ ]+\.key#-i $KEY#")"
# socat's EXEC splits on whitespace and ignores the shell quoting around the
# ProxyCommand argument: run the command from a script instead.
CONSOLE_RUN="$TMP/console-run.sh"
printf '#!/usr/bin/env bash\nexec %s\n' "$SSH_W_LOCAL" > "$CONSOLE_RUN"
chmod +x "$CONSOLE_RUN"

echo ""
echo "   Board is flashed and booting. Opening the serial console."
echo "   (Ctrl+D closes the console and releases the board.)"
echo ""
if command -v socat >/dev/null; then
  # escape=0x04: Ctrl+D ends the raw console as it does the line-mode one.
  socat -,raw,echo=0,escape=0x04 "EXEC:$CONSOLE_RUN,pty" || true
else
  echo "   NOTE: 'socat' not found: using line-buffered ssh -W instead of a raw tty."
  echo ""
  "$CONSOLE_RUN" || true
fi
