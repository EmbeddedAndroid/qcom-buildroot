# qcom/lava: flash a board in the LAVA lab

`submit.sh <tarball> <job-yaml>` flashes a board in the LAVA lab
(lava.infra.foundries.io) with a qcomflash tarball, where the board makefiles'
`flash-lava` targets would otherwise run qdl over USB (monaco.mk: `flash-lava`,
`flash-lava-yocto`). The job YAML names the device type, the qdl storage and
the files qdl writes; both modes below take them from it.

On a terminal it asks how to flash (default: interactive).
`FLASH_LAVA_CONNECT=1` selects interactive, `FLASH_LAVA_CONNECT=0` flash-only,
which is also the default without a terminal.

- flash-only: upload the tarball to the LAVA MCP artifact store, fill
  `<ARTIFACT_URL>` and `<ARTIFACT_TOKEN>` in the job YAML, submit it over the
  REST API and poll it until it finishes. `<ARTIFACT_TOKEN>` becomes the name
  of the LAVA remote artifact token that holds the upload secret, so the
  secret stays out of the job. The job's last boot action waits for a login
  prompt; the exit status is 0 only for health Complete.
- interactive, `connect.sh <tarball> <job-yaml>`: reserve a board and a
  container next to it through the LAVA MCP (`open_board_session` with the
  console), stage the tarball in the container, put the board in EDL (its
  `qdl_enter` command), flash it with qdl from the container, then attach its
  serial console. Ctrl+D closes the console and releases the board; any exit
  releases it.

## Requirements

- A LAVA API token (https://lava.infra.foundries.io/api/tokens/): `$LAVA_TOKEN`,
  or the lava MCP server in `~/.claude.json`, which the MCP needs anyway:

      claude mcp add --transport http lava https://lava.infra.foundries.io/mcp \
          --header "X-Lava-Token: <token>"

  The REST API takes it as `Authorization: Token <token>`, the MCP as
  `X-Lava-Token` (the older `C-Lava-Token` name is accepted when reading it).
- curl, jq and python3.
- Interactive only: ssh, websocat (fetched to `~/.local/bin` when missing),
  socat for a raw tty (without it the console is line-buffered), and a board
  of the device type in Good health that allows the serial-console proxy
  (`allow_test_services` in its device dictionary) and is tagged for remote
  access (`allow-remote-access`). connect.sh stops before uploading when no
  board qualifies.

If connect.sh is killed before it cleans up, release the board with the MCP
tool `close_board_session(<session id>)` or cancel the job it printed.

## Variables

`LAVA_URL`, `LAVA_MCP_URL`, `CLAUDE_JSON`, `LAVA_POLL_SECONDS`, `LAVA_POLL_MAX`
(flash-only polling), `FLASH_LAVA_DEVICE_TYPE` (overrides the job's
device_type), `FLASH_LAVA_EDL_CMD` (default `qdl_enter`),
`FLASH_LAVA_FLASH_TIMEOUT` (seconds for the in-container qdl, default 1200),
`FLASH_LAVA_CONNECT_MAX` (10-second polls for the session to connect).

Based on the lemans flash-lava scripts by Jorge Ramirez-Ortiz.
