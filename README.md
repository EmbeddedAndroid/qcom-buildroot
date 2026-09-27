# OP-TEE build.git

This repository is a **temporary fork** of the [OP-TEE build.git](https://github.com/OP-TEE/build)
project — the upstream build system for OP-TEE on open hardware platforms. It extends that build
system to support Qualcomm platforms so that Qualcomm developers can work on TZ open firmware using
the same tooling and workflows used across the OP-TEE ecosystem. The fork is temporary: the work
here is intended to be upstreamed to the public [OP-TEE repositories](https://github.com/OP-TEE/)
and retired once merged.

Build system for OP-TEE on Qualcomm platforms.  Each platform has its own
top-level makefile and subdirectory.

## Supported platforms

| Platform | SoC | Board | Makefile |
|----------|-----|-------|----------|
| Lemans | QCS9100 | Qualcomm IQ-9075 EVK | `lemans.mk` |
| Monaco | QCS8275 | Arduino VENTUNO Q | `monaco.mk` |

Files shared by the Qualcomm platforms (SWIV tool, UKI stub, qrtr-ns and
tqftpserv init scripts) live in `qcom/`.

## Quick start

IQ-9075 EVK (Lemans):

```sh
# Build everything
make -f lemans.mk all

# Get Qualcomm firmware blobs for flashing (pick one):
make -f lemans.mk fetch-blobs   # fast: direct download (minutes)
make -f lemans.mk yocto         # full OE/Yocto BSP build (hours)

# Flash
make -f lemans.mk flash-loader  # bootloader chain (first-time / after TF-A change)
make -f lemans.mk flash-kernel  # EFI partition only (kernel/initramfs iteration)
```

Arduino VENTUNO Q (Monaco):

```sh
make -f monaco.mk all           # bl2.elf + fip.elf (boot chain), efi.bin (kernel + rootfs)
make -f monaco.mk tz-qti-sign       # tz.mbn: QTI-signed BL2 (needs QTI remote signing access)

# Flash with the board in EDL mode; the eMMC firehose programmer goes in
# monaco/input/ (see monaco/input/README.md)
make -f monaco.mk flash-loader  # tz_a/tz_b + uefi_a/uefi_b
make -f monaco.mk flash-kernel  # efi partition only
```

## Firmware blobs (IQ-9075 EVK)

On the IQ-9075 EVK both `flash-loader` and `flash-kernel` need
Qualcomm-proprietary firmware binaries (XBL, AOP, firehose programmer, GPT
tables, rawprogram XMLs). These are resolved in priority order:

1. `{platform}/input/` — manually placed files
2. Yocto deploy directory — if `make yocto` has been run
3. `{platform}/blobs/` — populated by `make fetch-blobs`

`make fetch-blobs` downloads the boot binaries and CDT directly from public
Qualcomm/CodeLinaro URLs and generates partition tables via
[qcom-ptool](https://github.com/qualcomm-linux/qcom-ptool).
No Qualcomm account is required; the download takes a few minutes.

See `{platform}/input/README.md` for the full file-by-file breakdown.

## Documentation

HTML documentation is in `docs/`. Open `docs/index.html` as the landing page:
the board list, the pages shared by all boards (host setup, build system,
signing, flashing) and, per board, a board page and a quick start. Run
`node --test docs/_rtd.test.js` after changing the page list in
`docs/_rtd.js`.

## Further reading

- [OP-TEE documentation](https://optee.readthedocs.io)
- [Qualcomm Platform Docs](https://ldts.github.io/qcom-buildroot/)
