#!/usr/bin/env bash
# qcom/lava/submit.sh: flash a LAVA lab board with a qcomflash tarball.
#
# Called by `make flash-lava` / `make flash-lava-yocto` once the tarball is
# packaged. The board is flashed once, one of two ways (asked on a terminal,
# default Yes):
#   interactive  connect.sh reserves a board, flashes it from inside the
#                session container and opens its serial console
#   flash-only   upload the tarball, submit <job-yaml> as a one-shot qdl
#                deploy+boot job over the LAVA REST API and poll it until it
#                finishes; non-zero unless its health is Complete
# FLASH_LAVA_CONNECT=1 forces interactive, =0 forces flash-only; without a
# terminal (CI, piped stdin) it is flash-only.
#
# The upload goes to the LAVA MCP artifact store (create_artifact_upload);
# the job names the LAVA remote artifact token that holds the upload secret,
# so the secret stays out of the job definition. The LAVA API token comes
# from $LAVA_TOKEN or the lava MCP server's header in ~/.claude.json
# ($CLAUDE_JSON).
#
# Usage: submit.sh <tarball> <job-yaml>
#
# Based on lemans/lava/submit.sh by Jorge Ramirez-Ortiz.
set -euo pipefail

TARBALL="${1:?usage: submit.sh <tarball> <job-yaml>}"
JOB_YAML="${2:?usage: submit.sh <tarball> <job-yaml>}"

POLL_SECONDS="${LAVA_POLL_SECONDS:-20}"
POLL_MAX="${LAVA_POLL_MAX:-180}"   # 180 * 20 s = 60 min cap

[ -f "$TARBALL" ]  || { echo "ERROR: tarball not found: $TARBALL"  >&2; exit 1; }
[ -f "$JOB_YAML" ] || { echo "ERROR: job yaml not found: $JOB_YAML" >&2; exit 1; }
command -v curl >/dev/null || { echo "ERROR: 'curl' not found" >&2; exit 1; }
command -v jq   >/dev/null || { echo "ERROR: 'jq' not found" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
. "$(dirname "$0")/lib.sh"

TOK="$(lava_token)"
[ -n "$TOK" ] || { echo "ERROR: no LAVA token (set \$LAVA_TOKEN or add a lava MCP X-Lava-Token to $CLAUDE_JSON)" >&2; exit 1; }

# --- 1. interactive or flash-only -----------------------------------------------
CONNECT_SH="$(dirname "$0")/connect.sh"
interactive=""
case "${FLASH_LAVA_CONNECT:-}" in
  1) interactive="yes" ;;
  0) interactive="" ;;
  *)
    if [ -t 0 ]; then
      echo ""
      echo "Flash $(basename "$JOB_YAML") how?"
      echo "  [Y] interactive: reserve a board, flash it, open its serial console (default)"
      echo "  [n] flash-only:  submit a one-shot flash job and wait for it to boot remotely"
      printf 'Flash interactively and open the console? [Y/n] '
      read -r ans || ans=""
      case "$ans" in [nN]*) interactive="" ;; *) interactive="yes" ;; esac
    fi
    ;;
esac

if [ -n "$interactive" ]; then
  echo ">> opening an interactive session (single flash + console) via connect.sh ..."
  rm -rf "$TMP"
  exec "$CONNECT_SH" "$TARBALL" "$JOB_YAML"
fi

# --- 2. upload the tarball ------------------------------------------------------
echo ">> [1/3] uploading ..."
lava_upload "$TARBALL"

# --- 3. fill the job and submit it ----------------------------------------------
sed -e "s|<ARTIFACT_URL>|$GET_URL|g" -e "s|<ARTIFACT_TOKEN>|${UP_TOK_NAME:-$UP_TOK}|g" \
    "$JOB_YAML" > "$TMP/job.yaml"
jq -Rs '{definition: .}' "$TMP/job.yaml" > "$TMP/payload.json"

echo ">> [2/3] validating + submitting to $LAVA_URL ..."
VAL="$(curl -fsS -X POST -H "Authorization: Token $TOK" -H "Content-Type: application/json" \
       --data @"$TMP/payload.json" "$LAVA_URL/api/v0.3/jobs/validate/")"
echo "   validate: $VAL"
echo "$VAL" | grep -q '"Job valid."' || { echo "ERROR: job did not validate" >&2; exit 1; }

SUB="$(curl -fsS -X POST -H "Authorization: Token $TOK" -H "Content-Type: application/json" \
       --data @"$TMP/payload.json" "$LAVA_URL/api/v0.3/jobs/")"
JOB_ID="$(echo "$SUB" | jq -r '.job_ids[0]')"
[ -n "$JOB_ID" ] && [ "$JOB_ID" != null ] || { echo "ERROR: submit failed: $SUB" >&2; exit 1; }
echo "   submitted job $JOB_ID  ($LAVA_URL/scheduler/job/$JOB_ID)"

# --- 4. wait for the board to flash and boot ------------------------------------
# The job's last boot action waits for a login prompt, so health Complete
# means the board flashed AND booted.
echo ">> [3/3] monitoring job $JOB_ID (flashing, then booting to a login prompt) ..."
last=""; HEALTH=""
for _ in $(seq 1 "$POLL_MAX"); do
  J="$(curl -fsS -H "Authorization: Token $TOK" "$LAVA_URL/api/v0.3/jobs/$JOB_ID/")"
  state="$(echo "$J" | jq -r '.state')"; health="$(echo "$J" | jq -r '.health')"
  dev="$(echo "$J" | jq -r '.actual_device // "-"')"
  now="$state/$health@$dev"
  [ "$now" != "$last" ] && { echo "   $now"; last="$now"; }
  if [ "$state" = "Finished" ]; then
    echo ">> job $JOB_ID finished: health=$health"
    HEALTH="$health"; break
  fi
  sleep "$POLL_SECONDS"
done
if [ -z "$HEALTH" ]; then
  echo "WARNING: job $JOB_ID still running after poll cap; check $LAVA_URL/scheduler/job/$JOB_ID" >&2
  exit 0
fi
[ "$HEALTH" = "Complete" ] && exit 0 || exit 2
