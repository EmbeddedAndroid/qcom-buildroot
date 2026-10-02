# shellcheck shell=bash
# qcom/lava/lib.sh: helpers shared by submit.sh and connect.sh (sourced).
#
# The callers set TMP (a scratch directory) and JOB_YAML before using them.
#
#   lava_token           print the LAVA API token: $LAVA_TOKEN, else the
#                        X-Lava-Token (or older C-Lava-Token) header of the
#                        lava MCP server in $CLAUDE_JSON (~/.claude.json)
#   mcp <tool> <json>    call one LAVA MCP tool over JSON-RPC and print its
#                        text payload ({} for no arguments)
#   jq_field <json> <f>  apply a jq filter to a tool payload, never failing
#   yaml_val <key>       the first value of <key> in $JOB_YAML
#   lava_upload <file>   upload <file> to the LAVA MCP artifact store; sets
#                        GET_URL, UP_TOK (the secret) and UP_TOK_NAME (the
#                        LAVA remote artifact token holding it, or empty)
#   console_board <type> print a Good board of device type <type> that allows
#                        the serial-console proxy, or nothing
#
# Based on lemans/lava/connect.sh by Jorge Ramirez-Ortiz.

LAVA_URL="${LAVA_URL:-https://lava.infra.foundries.io}"
MCP_URL="${LAVA_MCP_URL:-$LAVA_URL/mcp}"
CLAUDE_JSON="${CLAUDE_JSON:-$HOME/.claude.json}"

lava_token() {
  if [ -n "${LAVA_TOKEN:-}" ]; then
    printf '%s\n' "$LAVA_TOKEN"
    return
  fi
  [ -f "$CLAUDE_JSON" ] || return 0
  python3 - "$CLAUDE_JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
cands = [d.get("mcpServers", {})]
cands += [p.get("mcpServers", {}) for p in d.get("projects", {}).values()]
for m in cands:
    lava = m.get("lava")
    if lava:
        h = lava.get("headers", {})
        t = h.get("X-Lava-Token") or h.get("C-Lava-Token")
        if t:
            print(t); break
PY
}

# mcp() opens an MCP session when the shell has none; called from a command
# substitution, that is one session per call. The server reads the token from
# the X-Lava-Token header.
MCP_SID=""; MCP_RPC_ID=0
MCP_MAX_TIME="${MCP_MAX_TIME:-600}"

mcp_init() {
  local hf="$TMP/mcp.hdr"
  MCP_HDRS=(-H "X-Lava-Token: $TOK" -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream")
  curl -fsS -D "$hf" -o "$TMP/mcp.init" -X POST "$MCP_URL" "${MCP_HDRS[@]}" \
    --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"qcom-lava","version":"1"}}}' \
    || { echo "ERROR: MCP initialize failed (is $MCP_URL reachable, token valid?)" >&2; return 1; }
  MCP_SID="$(grep -i '^mcp-session-id:' "$hf" | tr -d '\r' | awk '{print $2}')"
  [ -n "$MCP_SID" ] || { echo "ERROR: MCP returned no session id" >&2; return 1; }
  curl -fsS -X POST "$MCP_URL" "${MCP_HDRS[@]}" -H "Mcp-Session-Id: $MCP_SID" \
    --data '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null || true
}

# The streamable-http endpoint may answer as a text/event-stream: strip the
# "data: " prefixes before parsing the JSON-RPC envelope.
mcp() {
  local tool="$1" args="${2:-{\}}"
  [ -n "$MCP_SID" ] || mcp_init || return 1
  MCP_RPC_ID=$((MCP_RPC_ID+1))
  local req
  req="$(jq -nc --arg n "$tool" --argjson a "$args" --argjson id "$MCP_RPC_ID" \
          '{jsonrpc:"2.0",id:$id,method:"tools/call",params:{name:$n,arguments:$a}}')"
  curl -fsS --max-time "$MCP_MAX_TIME" -X POST "$MCP_URL" "${MCP_HDRS[@]}" \
       -H "Mcp-Session-Id: $MCP_SID" --data "$req" 2>/dev/null \
    | sed -e 's/^data: //' \
    | jq -rs '[ .[] | select(.result) | .result.content[]? | select(.type=="text") | .text ] | last // ""' 2>/dev/null \
    || true
}

jq_field() { printf '%s' "$1" | jq -r "$2" 2>/dev/null || true; }

# grep exits non-zero when nothing matches; a missing key yields "".
yaml_val() { { grep -E "^[[:space:]]*$1:" "$JOB_YAML" | grep -v '^[[:space:]]*#' | head -1 | sed -E "s/^[[:space:]]*$1:[[:space:]]*//"; } || true; }

lava_upload() {
  local f="$1" fn sz mint
  fn="$(basename "$f")"; sz="$(stat -c%s "$f")"
  echo ">> uploading $fn ($(( sz/1024/1024 )) MB) to the LAVA MCP artifact store ..."
  mint="$(mcp create_artifact_upload "$(jq -nc --arg f "$fn" --argjson s "$sz" '{filename:$f,size_bytes:$s}')")"
  GET_URL="$(jq_field "$mint" '.get_url // empty')"
  UP_TOK="$(jq_field "$mint" '.token // empty')"
  UP_TOK_NAME="$(jq_field "$mint" 'if .remote_artifact_token.registered then .remote_artifact_token.name else empty end')"
  [ -n "$GET_URL" ] && [ -n "$UP_TOK" ] || { echo "ERROR: create_artifact_upload returned no get_url/token" >&2; return 1; }
  curl -fsS -T "$f" -H "Authorization: $UP_TOK" "$GET_URL" >/dev/null || { echo "ERROR: upload to $GET_URL failed" >&2; return 1; }
  echo "   stored at $GET_URL"
}

console_board() {
  local devs h
  devs="$(mcp list_devices "$(jq -nc --arg t "$1" '{device_type:$t, health:"Good"}')")"
  for h in $(jq_field "$devs" '.results[]?.hostname'); do
    if [ "$(jq_field "$(mcp check_serial_console_support "$(jq -nc --arg h "$h" '{hostname:$h}')")" '.ok')" = true ]; then
      echo "$h"
      return
    fi
  done
}
