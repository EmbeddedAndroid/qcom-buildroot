# kodiak/input: files the build does not produce

Place these here before flashing; they are not tracked in git.

| File | Needed by | Description |
|------|-----------|-------------|
| `prog_firehose_ddr.elf` | `flash-loader`, `flash-kernel`, `flash-lava` | UFS firehose programmer qdl loads in EDL mode, from the board's boot binaries (QCM6490 boot binaries, the `test-device-public` release on the Qualcomm software center, or the qcomflash package of the RB3 Gen 2 Yocto image). The one used to test this build (boot binaries 00126) has SHA-256 `1da8d5ca211561feff54285a8d3284afb8f58fd872566f2ff6e3d157322286db`. Override the location with `FIREHOSE=<path>`. |
| `tz.mbn` | `flash-loader` | Optional. A QTI-signed TF-A BL2 for users without access to the QTI remote signing service. `flash-loader` uses `kodiak/output/tz.mbn` (from `make tz-qti-sign`) when it exists and this file otherwise. |

The tz partition image must carry a QTI signature: XBL rejects a TZ image
signed with qtestsign on Kodiak even with secure boot disabled. BL2 loads
BL31, OP-TEE and U-Boot from the FIP in the uefi partition; sign a new
tz.mbn whenever the TF-A tree changes.
