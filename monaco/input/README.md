# monaco/input: files the build does not produce

Place these here before flashing; they are not tracked in git.

| File | Needed by | Description |
|------|-----------|-------------|
| `prog_firehose_ddr.elf` | `flash-loader`, `flash-kernel` | eMMC firehose programmer qdl loads in EDL mode, from the board's stock software image (its qcomflash package). The one used to test this build has SHA-256 `988460433a60d48891f56dccf2a17556dd57597c188546f46fd6ad920c6df977`. Override the location with `FIREHOSE=<path>`. |
| `tz.mbn` | `flash-loader` | Optional. A QTI-signed TF-A BL2 for users without access to the QTI remote signing service. `flash-loader` uses `monaco/output/tz.mbn` (from `make tz-qti-sign`) when it exists and this file otherwise. |

The tz partition image must carry a QTI signature: XBL rejects a TZ image
signed with qtestsign on Monaco even with secure boot disabled. BL2 loads
BL31, OP-TEE and U-Boot from the FIP in the uefi partition; sign a new
tz.mbn whenever the TF-A tree changes.
