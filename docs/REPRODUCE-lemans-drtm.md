# Reproduce the Lemans DRTM build (IQ-9075 EVK)

This builds the Lemans dTPM + DRTM boot chain from `manifests/lemans.xml`
on a clean host, flashes it to an IQ-9075 EVK and tells you what the
console must show at every stage. The build and check commands below were
run verbatim on a fresh host; the USB flash command was not (see "Tested"
at the end).

What you get: the commits `manifests/lemans.xml` pins, which are the
commits tested below. Every project is pinned to a commit; `upstream`
names the branch it came from (for the DRTM trees, `features/lemans/drtm`
on github.com/EmbeddedAndroid). A pin moves only together with the LAVA
proof of the new set.

    XBL (test-device boot binaries)
      -> U-Boot SPL (tz.mbn, qtestsign signed)
      -> TF-A BL31 (SPD=spmd, DRTM service, dTPM firewall)
      -> OP-TEE (S-EL1 SPMC, owns the dTPM on QUP2 SE2)
      -> U-Boot proper (default boot: drtm launch of dlme.img)
      -> TF-A BL31 as the DCE (PCR 17: DCE and schema; PCR 18: dlme.img)
      -> Xen as the DLME (measures dom0 into PCR 19)
      -> Linux dom0 (Buildroot initramfs)

`lemans.mk` defaults to `XEN=y DRTM=y`. `QTI_SECURE_DTPM=1` adds the dTPM
firewall: BL31 makes QUP2 SE2 and the TPM pads (GPIO 86-89) secure only, so
the normal world (U-Boot, Xen, Linux) reaches the TPM only through OP-TEE.
This note always builds with it.

## Host

- Ubuntu 24.04 with Docker; everything else runs in the container below.
  Tested on x86_64. The container and `make toolchains` also handle an
  aarch64 host; this note was not run on one.
- Disk: about 40 GB free (the workspace is 30 GB after a build, plus
  the container image). The test host had 16 CPUs and 32 GB of RAM;
  the build took 1 h 42 min there, from an empty workspace.
- Network: the build fetches from github.com, review.trustedfirmware.org
  (TF-A), developer.arm.com (`make toolchains`), git.kernel.org and
  cdn.kernel.org (linux-firmware, Buildroot sources), sh.rustup.rs,
  static.rust-lang.org and files.pythonhosted.org (host tools),
  softwarecenter.qualcomm.com (the public test-device boot binaries),
  artifacts.codelinaro.org (CDT) and the usual Buildroot package sites
  (sources.buildroot.net as the fallback).
- Board: an IQ-9075 EVK that boots test-signed images (the boot binaries
  are QCS9100 `test-device-public`, the SPL is signed with qtestsign). A
  secure-boot fused board does not boot this chain.

Install Docker once:

```sh
sudo apt-get update
sudo apt-get install -y docker.io git
sudo usermod -aG docker "$USER"
```

Log out and back in (or run `newgrp docker`) so `docker` works without
sudo.

## 1. Build container

```sh
mkdir -p ~/lemans-drtm/container
cat > ~/lemans-drtm/container/Dockerfile <<'EOF'
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8
RUN apt-get update && apt-get install -y --no-install-recommends \
	ca-certificates curl wget xz-utils git make build-essential \
	device-tree-compiler libssl-dev python3 python3-cryptography \
	python3-pyelftools python3-setuptools python3-dev swig \
	libgnutls28-dev uuid-dev perl u-boot-tools file bc bison flex \
	libelf-dev cpio kmod rsync unzip zstd lz4 dosfstools mtools fdisk \
	e2fsprogs python3-yaml ccache patch gawk bzip2 libncurses-dev \
	pkg-config systemd-boot-efi python3-pefile systemd-ukify \
	python3-venv ffmpeg xxd bsdextrautils cmake \
	&& rm -rf /var/lib/apt/lists/* \
	&& git config --system safe.directory '*' \
	&& curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo \
	   -o /usr/local/bin/repo && chmod 755 /usr/local/bin/repo
EOF
docker build -t lemans-drtm-build ~/lemans-drtm/container
```

## 2. Sync and build

Pick a build fingerprint. It ends up in every stage's banner (SPL, BL31,
OP-TEE, U-Boot, Xen, Linux), which is how you know the board runs what you
just built. Use a new one for every build; never reuse one.

```sh
export FP=QCDFP-$(date -u +%y%m%d)-0001
mkdir -p ~/lemans-drtm/ws
docker run -it --rm -u "$(id -u):$(id -g)" -e HOME=/ws/.home -e FP \
	-v ~/lemans-drtm/ws:/ws -w /ws lemans-drtm-build bash
```

Inside the container:

```sh
mkdir -p "$HOME"
git config --global user.name "lemans build"
git config --global user.email build@localhost
git config --global color.ui false
repo init -u https://github.com/EmbeddedAndroid/qcom-buildroot \
	-b features/lemans/security/dtpm-drtm -m manifests/lemans.xml
repo sync -j8 --no-clone-bundle
repo manifest -r -o manifest-pinned.xml
cd build
M="QTI_SECURE_DTPM=1 LOCALVERSION=-$FP"
make -j"$(nproc)" toolchains
make all $M
make bootimage $M
make flash-lava-package $M
```

Stop at the first command that fails. Pass the same `$M` to every `make`
you run in this workspace: `bootimage` rebuilds OP-TEE, TF-A and U-Boot,
and a run without `QTI_SECURE_DTPM=1` would not carry the firewall.

`repo init -b` takes the manifest from the branch head; when the pins
have moved past the set in "Tested", init from the commit or tag that
added it instead.

`manifest-pinned.xml` records the exact commit of every tree; keep it with
the build. Two inputs are pinned nowhere: `make` clones qtestsign from its
default branch, and `make toolchains` installs the current stable Rust
through rustup. The boot binaries (`BLOBS_VERSION` 00132), the CDT,
qcom-ptool and linux-firmware are pinned in lemans.mk by version and
SHA-256 or by commit.

## 3. Outputs

In `~/lemans-drtm/ws/build/lemans/output/`:

| file | what | flashed to |
|---|---|---|
| `tz.mbn` | U-Boot SPL, SWIV annotated, qtestsign signed | `tz_a`/`tz_b` (LUN 4) |
| `uefi.elf` | FIT: BL31 (load 0x1c200000), OP-TEE (0x1c300000), U-Boot proper (0xaf000000) and its control DTB | `uefi_a`/`uefi_b` (LUN 4) |
| `efi.bin` | FAT ESP: `dlme.img` (what U-Boot launches), and for a static boot by hand `EFI/BOOT/bootaa64.efi` = Xen, `bootaa64.cfg`, dom0 `Image`, initramfs, DTB | `efi` (LUN 0) |
| `dlme.img` | the DLME: trampoline, Xen's device tree, Xen, dom0 `Image` and initramfs, for 0x180000000 | inside `efi.bin` |
| `dlme-pcr.txt` | PCR 17/18/19 (sha256, sha384) a launch of this `dlme.img` must leave | not flashed |
| `lemans-flash.qcomflash.tar.gz` | everything above plus the boot binaries, GPTs, rawprogram/patch XMLs and `qupv3fw.elf`, flat | the whole flash set |

Check that the fingerprint made it into every binary (each count must be 1
or more) and that the ELFs for a debugger (section 4) are there:

```sh
cd ~/lemans-drtm/ws
: "${FP:?set FP to the fingerprint of the build}"
for f in build/lemans/output/tz.mbn build/lemans/output/uefi.elf \
	build/lemans/output/efi.bin; do
	echo "$f $(grep -a -c "$FP" "$f")"
done
ls -l u-boot/.output/spl/u-boot-spl \
	arm-trusted-firmware/build/lemans_evk/release/bl31/bl31.elf \
	optee_os/out/arm/core/tee.elf u-boot/.output-proper/u-boot \
	out/xen/xen-syms linux/vmlinux
```

The rootfs is the initramfs inside `efi.bin`; nothing is written to the
rootfs partition.

## 4. Flash

### Over USB (EDL)

Put the board in EDL (USB 05c6:9008) and run qdl on the host with the file
list the LAVA qdl deploy uses (LAVA also passes `--storage ufs`). Build
qdl from https://github.com/linux-msm/qdl (the lab runs v2.7) or install
the Ubuntu 24.04 package (`sudo apt-get install qdl`, a 2023 snapshot, not
tested); run it with sudo unless a udev rule grants access to 05c6:9008.

```sh
mkdir -p ~/lemans-drtm/flash
tar -C ~/lemans-drtm/flash -xzf \
	~/lemans-drtm/ws/build/lemans/output/lemans-flash.qcomflash.tar.gz
cd ~/lemans-drtm/flash
qdl --storage ufs prog_firehose_ddr.elf rawprogram0-only-kernel.xml \
	rawprogram1.xml rawprogram2.xml rawprogram3.xml rawprogram4-qupfw.xml \
	rawprogram5.xml patch0.xml
```

Then power cycle the board out of EDL.

### Through LAVA

`make flash-lava $M` packages the same tarball and submits
`lemans/lava/flash-lava-xen.yaml` through `lemans/lava/submit.sh`, which
needs a lava.infra.foundries.io token, `jq` and the `claude` CLI (see
`lemans/lava/README.md`). The job flashes the rawprogram list above and
boots to the dom0 shell; it does not check the PCRs (compare them by
hand, section 6).

### On a board with JTAG

Flashing does not change: use EDL as above. The JTAG probe is for
debugging the chain this build produces. Symbols, from
`~/lemans-drtm/ws`:

| stage | ELF | runs at |
|---|---|---|
| U-Boot SPL | `u-boot/.output/spl/u-boot-spl` | 0x1c100000 (`CONFIG_SPL_TEXT_BASE`) |
| BL31 | `arm-trusted-firmware/build/lemans_evk/release/bl31/bl31.elf` | 0x1c200000 (EL3) |
| OP-TEE | `optee_os/out/arm/core/tee.elf` | 0x1c300000 (S-EL1) |
| U-Boot proper | `u-boot/.output-proper/u-boot` | 0xaf000000, then relocates itself (`bdinfo` shows `relocaddr`) |
| Xen | `out/xen/xen-syms` | 0x180200000 (dlme.img + 0x200000), EL2; BL31 enters the trampoline at 0x180000000 |
| Linux dom0 | `linux/vmlinux` | EL1 under Xen |

Things that bite under a debugger:

- U-Boot arms the APSS watchdog at start (`CONFIG_WATCHDOG_AUTOSTART=y` in
  `qcom_lemans_defconfig`; console `WDT:   Started watchdog@17c10000 with
  servicing every 1000ms (30s timeout)`). A halt in U-Boot can trip
  it; the `drtm` command stops it before a dynamic launch.
- With `QTI_SECURE_DTPM=1`, QUP2 SE2 and the TLMM pads of GPIO 86-89 are
  secure only. A non-secure debugger access to them faults like a normal
  world access would; use secure accesses there.

## 5. What the console shows

One UART (115200 8N1) carries every stage; under Xen, dom0 logs in on hvc0
behind it. With `FP=QCDFP-YYMMDD-NNNN`, in this order:

    U-Boot SPL 2026.07-rc4-<FP>-00129-gbcb173bae4a4-dirty (...)
    NOTICE:  BL31: v2.15.0(release):<FP>
    I/TC: OP-TEE version: <FP> (gcc version 14.3.1 ...) ... aarch64
    I/TC: TPM2 SPI: TPM detected, DID_VID=0x104a (ready after 1 probe)
    I/TC: Primary CPU switching to normal world boot
    U-Boot 2026.07-rc4-<FP>-00129-gbcb173bae4a4-dirty (...)
    optee optee: OP-TEE api uid mismatch
    DRTM version 1.0
    DRTM: launching DLME at 0x180000000
    (XEN) Command line: ... drtm-tpm=0x8100
    Xen 4.23-unstable-<FP>
    (XEN) Xen version 4.23-unstable-<FP> ...
    (XEN) Using TEE mediator for FF-A
    (XEN) DRTM: PCR 19 kernel <sha256>: 0
    (XEN) DRTM: PCR 19 initrd <sha256>: 0
    (XEN) DRTM: PCR 19 cmdline <sha256>: 0
    (XEN) DRTM: TPM locality 2 closed (-6)
    [    0.000000] Linux version 7.1.0-rc6-<FP>-g88b52b9a79bb ...
    optee: api uid mismatch
    optee: revision 4.11 (86156c9f)
    buildroot login:

Log in as `root` (no password). `uname -r` and `xl info` show the same
fingerprint. A banner with another fingerprint (or none) means the board
did not boot what you flashed: reflash before debugging anything.

U-Boot prints `optee optee: OP-TEE api uid mismatch`: its OP-TEE driver
only speaks the SMC ABI, OP-TEE runs as the FF-A SPMC here, and U-Boot has
no FF-A transport, so U-Boot has no TPM access. Expected. dom0's kernel
prints the same line when it probes the SMC conduit, then finds OP-TEE
over FF-A (`optee: revision ...`).

## 6. Dynamic launch (DRTM)

U-Boot's default boot command is the dynamic launch: `drtm info`, load
`dlme.img` from the ESP to 0x180000000, `drtm launch` (the command is
documented in the u-boot tree, `doc/usage/cmd/drtm.rst`). BL31 extends
PCR 17 (DCE, PCR schema) and PCR 18 (dlme.img) at locality 4 and enters
Xen, which measures the dom0 kernel, initramfs and command line into PCR
19 at locality 2 and closes locality 2. In dom0 both banks must equal
`dlme-pcr.txt` of the build:

    for b in sha256 sha384; do for p in 17 18 19; do
        echo "PCR $b $p $(cat /sys/class/tpm/tpm0/pcr-$b/$p)"
    done; done

There is no fallback to a static boot. When the firmware has no DRTM
service, an earlier launch left an error code or `dlme.img` is missing,
U-Boot prints a `DRTM: ...` line and stops at its prompt; so does a
launch refused before the quiesce. A launch refused after it records the
error code and resets the board, and the next boot stops. `drtm info`
shows the error code, `drtm clear` clears it and re-arms the launch.
`run do_boot` boots Xen statically by hand (no D-RTM measurement). A
saved U-Boot environment overrides the default boot command;
`env default -a; saveenv` restores it.

## Tested

2026-11-27, on a fresh Ubuntu 24.04 x86_64 VM (16 CPUs, 32 GB). A first
run (FP 3214) installed Docker and built the container there, then
stopped at `make toolchains` (rustup download timeout); this run reused
that VM with an empty workspace: the sh blocks of sections "Host" to
"3. Outputs" were run verbatim in order, with `FP=QCDFP-261127-3215` and
the `docker run` of section 2 given the in-container block instead of a
terminal. This branch and the u-boot commit it pins were not pushed yet,
so the `docker run` also mounted local mirrors of both and git
`url.insteadOf` sent their URLs there. The mirror held an earlier
revision of this commit that differs only in this section and in prose
(its sh blocks and `manifests/lemans.xml` are identical to this
commit's). Every other tree came from its own remote. Trees as synced:

| tree | commit |
|---|---|
| build | 8c957ef95689 |
| arm-trusted-firmware | 6f3827d76d0d |
| optee_os | 86156c9f9a53 |
| u-boot | bcb173bae4a4 |
| xen | 6f4c26555bdb |
| linux | 88b52b9a79bb |
| test-definitions | b14bf67bdd82 |
| optee_test | e92a1880e74b |

The flash tarball booted two IQ-9075 EVKs through LAVA (qdl v2.7, the
rawprogram list of section 4). Each job checks the fingerprint in every
stage, the default boot's launch, Xen's PCR 19 events, and PCR 17/18/19
of both banks in dom0 against `dlme-pcr.txt`:

- https://lava.infra.foundries.io/scheduler/job/625489 (SPL #L2308, BL31 #L2313, OP-TEE #L2327, U-Boot #L2347,
  launch #L2393, Xen #L2470, PCR 19 #L2620-2630, locality 2 closed
  #L2635, Linux #L2679, PCRs 6/6 #L3877-3937)
- https://lava.infra.foundries.io/scheduler/job/625490 (SPL #L2309, U-Boot #L2348, launch #L2394, Linux #L2680,
  PCRs 6/6 #L3880-3939)

The same tarball with one padding byte at the end of `dlme.img` changed
on the ESP launched as well, and left PCR 18 (both banks) at the values
replayed for the changed image and PCR 17 and 19 as above:
https://lava.infra.foundries.io/scheduler/job/625491 (PCR 18 #L3819, #L3855; PCRs 6/6 #L3810-3870).

Not tested: a run of this note from github.com (after the push), `qdl`
from a desk host over USB (the lab runs the same command from its own
worker), the Ubuntu-packaged `qdl`, `make flash-lava`, an aarch64 host,
the U-Boot stop paths of section 6 on a board, and a JTAG probe.
