# kodiak/input: files the build does not produce

Optional; not tracked in git.

| File | Needed by | Description |
|------|-----------|-------------|
| `tz.mbn` | `flash-loader`, `flash-lava` | Optional. A TF-A BL2 signed elsewhere. The flash targets use `kodiak/output/tz.mbn` (from `make bootimage`, `make tz-oem-sign` or `make tz-qti-sign`) when it exists and this file otherwise. |

The flash targets take the boot binaries (XBL, XBL config, AOP and the rest
of the QCM6490 boot firmware) and the UFS firehose programmer from the
QCM6490 boot binaries release that `make bootbinaries-fetch` downloads into
`kodiak/blobs/bootbinaries/`; `FIREHOSE=<path>` overrides the programmer.
The XBL of that release accepts the OEM TEST-signed `tz.mbn` that
`make bootimage` produces; an older XBL does not boot it. BL2 loads BL31,
OP-TEE and U-Boot from the FIP in the uefi partition; sign a new tz.mbn
whenever the TF-A tree changes.
