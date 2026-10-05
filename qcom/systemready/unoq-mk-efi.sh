#!/usr/bin/env bash
# mk-efi.sh <FP> <kernel dir> <test-definitions rev>: UNO Q open stack ESP
# images, built in monza-build:2 (laptop):
#   docker run --rm -u $(id -u):$(id -g) -v $HOME/monza:/monza monza-build:2 \
#     bash /monza/unoq-port/build/mk-efi.sh <FP> /monza/unoq-port/out/<KFP>/linux <rev>
#
# Kernel, DTB and modules come from build-linux.sh. The initramfs is the
# VENTUNO Q Buildroot test userspace (xtest, tee-supplicant, TAs, stress-ng,
# busybox, kvmtool, kvm-unit-tests and the KVM test guest from
# MONZAFP-261002-003420 on) of the VENTUNO Q build VQ_BUILD (default
# MONZAFP-261001-153751) plus an overlay archive: /etc/issue with <FP>, the
# kernel modules (MODULES, loaded at boot; default the USB PHY drivers and
# LMh), and the open-boot-stack test definitions at <rev> in /opt/td.
# The UKI (qcom-buildroot's linuxaa64.efi.stub) goes into a 256 MiB FAT32 ESP
# as EFI/Linux/uki.efi and EFI/BOOT/bootaa64.efi, which U-Boot's
# "bootefi bootmgr" autoboot starts. One ESP per command line:
#   efi.bin (default), efi-cpusN.bin (maxcpus=N), efi-memtest4.bin (memtest=4),
#   efi-negative.bin (maxcpus=2 kvm-arm.mode=none, for the negative control).
# DTB names the device tree in the kernel dir (default the board DTB),
# OVERLAY directories (colon separated) copied over the overlay root last, in
# order (firmware, init scripts), TD_EXTRA more test-definitions paths for /opt/td, ESP_SIZE the
# ESP image size (default 256M; the efi partition holds 512M). UKI_LINUX_COPY=0
# leaves EFI/Linux/uki.efi out (U-Boot starts EFI/BOOT/bootaa64.efi), for a UKI
# too large to fit twice.
# INITRD_DROP=<file> builds one archive instead of appending the overlay to the
# VENTUNO Q initramfs: initrd-merge.py drops the paths the file lists (VENTUNO
# Q firmware and DSP runtime, files the UNO Q never uses) and the files the
# overlay replaces, then INITRD_COMP (default gzip -9n; zstd for zstd -19)
# compresses it. OVERLAY_EXCLUDE (colon separated, relative paths) removes
# files from the overlay root after the OVERLAY copies (an overlay's own Mesa
# when the base already has the one to use). EXTRA_CMDLINE is appended to
# every command line (diagnostics such as efi=debug). MODULES_ONLY=1 keeps only
# the MODULES and their dependencies from the kernel's modules (depmod again).
set -euo pipefail
FP=${1:?fingerprint}
KDIR=${2:?kernel dir}
TDREV=${3:?test-definitions revision}
VQ_BUILD=${VQ_BUILD:-MONZAFP-261001-153751}
VQ=/monza/out/qcom-buildroot/$VQ_BUILD/uki.efi
MODULES=${MODULES-phy-qcom-qusb2 phy-qcom-qmp-usbc lmh}
DTB=${DTB:-qrb2210-arduino-imola.dtb}
OVERLAY=${OVERLAY:-}
TD_EXTRA=${TD_EXTRA:-}
ESP_SIZE=${ESP_SIZE:-256M}
UKI_LINUX_COPY=${UKI_LINUX_COPY:-1}
INITRD_DROP=${INITRD_DROP:-}
INITRD_COMP=${INITRD_COMP:-gzip}
OVERLAY_EXCLUDE=${OVERLAY_EXCLUDE:-}
EXTRA_CMDLINE=${EXTRA_CMDLINE:-}
MODULES_ONLY=${MODULES_ONLY:-}
STUB=/monza/upstream/qcom-buildroot/qcom/ukify/linuxaa64.efi.stub
TD=/monza/upstream/test-definitions
OUT=/monza/unoq-port/out/$FP
CMDLINE="root=/dev/ram0 rw console=ttyMSM0,115200 earlycon clk_ignore_unused pd_ignore_unused qcom_scm.download_mode=1${EXTRA_CMDLINE:+ $EXTRA_CMDLINE}"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$OUT"
(cd $KDIR && sha256sum -c --quiet SHA256SUMS)

python3 - $VQ .initrd $W/initrd.vq <<'PY'
import struct, sys
f = open(sys.argv[1], 'rb').read()
pe = struct.unpack_from('<I', f, 0x3c)[0]
nsec = struct.unpack_from('<H', f, pe + 6)[0]
sh = pe + 24 + struct.unpack_from('<H', f, pe + 20)[0]
for i in range(nsec):
    name, vsize, _, rawsize, rawptr = struct.unpack_from('<8sIIII', f, sh + 40 * i)
    if name.rstrip(b'\0').decode() == sys.argv[2]:
        open(sys.argv[3], 'wb').write(f[rawptr:rawptr + min(vsize, rawsize)])
        sys.exit(0)
sys.exit('no section ' + sys.argv[2])
PY

# The kernel unpacks concatenated archives in order, so the overlay archive
# replaces or adds files without unpacking the original (it holds device
# nodes).
R=$W/root
mkdir -p $R/etc/init.d $R/opt/td
printf 'UNOQ build fingerprint: %s\n\n' "$FP" > $R/etc/issue
printf '#!/bin/sh\nexit 0\n' > $R/etc/init.d/S60fastrpc
printf '#!/bin/sh\n[ "$1" = start ] && modprobe -a %s\nexit 0\n' "$MODULES" \
	> $R/etc/init.d/S05modules
chmod 755 $R/etc/init.d/S60fastrpc $R/etc/init.d/S05modules
tar -C $R -xzf $KDIR/modules.tar.gz
if [ -n "$MODULES_ONLY" ]; then
	# Only the modules S05modules loads and what they depend on: nothing
	# else loads modules (no hotplug helper), so the rest is dead weight.
	kver=$(ls $R/lib/modules)
	python3 - $R/lib/modules/$kver $MODULES <<'PY'
import os, sys
d, want = sys.argv[1], {m.replace("-", "_") for m in sys.argv[2:]}
dep = {}
for l in open(os.path.join(d, "modules.dep")):
    k, v = l.split(":", 1)
    dep[k] = v.split()
by_name = {os.path.basename(k).split(".ko")[0].replace("-", "_"): k for k in dep}
missing = want - set(by_name)
if missing:
    sys.exit("modules not built: %s" % sorted(missing))
keep, todo = set(), [by_name[m] for m in want]
while todo:
    k = todo.pop()
    if k not in keep:
        keep.add(k)
        todo += dep[k]
for k in dep:
    if k not in keep:
        os.remove(os.path.join(d, k))
print("modules: kept %d of %d" % (len(keep), len(dep)))
PY
	find $R/lib/modules/$kver -type d -empty -delete
	depmod -b $R $kver
fi
git -C $TD archive $TDREV automated/lib automated/utils automated/bin \
	automated/linux/boot-fingerprint automated/linux/boot-handoff \
	automated/linux/cpufreq-policy automated/linux/maxcpus \
	automated/linux/memtest automated/linux/kernel-health \
	automated/linux/optee automated/linux/kvm-unit-tests \
	automated/linux/kvm-guest $TD_EXTRA | tar -C $R/opt/td -xf -
echo "$TDREV" > $R/opt/td/REVISION
install -m 755 /monza/unoq-port/build/local-suite.sh $R/opt/td/local-suite.sh
printf 'KFP=%s\nRFP=%s\n' "$(sed 's/^[^-]*-//; s/+$//' $KDIR/kernel.release)" "$FP" > $R/etc/fp
for o in ${OVERLAY//:/ }; do cp -a "$o/." $R/; done
for x in ${OVERLAY_EXCLUDE//:/ }; do
	[ -e "$R/$x" ] || [ -L "$R/$x" ] || { echo "OVERLAY_EXCLUDE: no $x"; exit 1; }
	rm -rf "${R:?}/$x"
done
if [ -n "$INITRD_DROP" ]; then
	(cd $R && find etc lib opt $(cd $R && ls -d usr 2>/dev/null) | LC_ALL=C sort | cpio -o -H newc --quiet -R 0:0) > $W/overlay.cpio
	python3 /monza/unoq-port/build/initrd-merge.py $W/initrd.vq $W/overlay.cpio "$INITRD_DROP" $W/initrd.cpio | tee $W/initrd-merge.txt
	case $INITRD_COMP in
	gzip) gzip -9n < $W/initrd.cpio > $W/initrd ;;
	zstd) zstd -q -19 -T0 < $W/initrd.cpio > $W/initrd ;;
	*) echo "INITRD_COMP: $INITRD_COMP"; exit 1 ;;
	esac
else
	cp $W/initrd.vq $W/initrd
	(cd $R && find etc lib opt $(cd $R && ls -d usr 2>/dev/null) | LC_ALL=C sort | cpio -o -H newc --quiet -R 0:0 | gzip -9n) >> $W/initrd
fi

uname=$(cat $KDIR/kernel.release)
rm -f $OUT/efi*.bin $OUT/uki*.efi
for v in ":"; do
	sfx=${v%%:*}; extra=${v#*:}
	ukify build --stub=$STUB --linux=$KDIR/Image --initrd=$W/initrd \
		--devicetree=$KDIR/$DTB --uname="$uname" \
		--cmdline="$CMDLINE${extra:+ $extra}" --output=$OUT/uki$sfx.efi > /dev/null
	img=$OUT/efi$sfx.bin
	truncate -s $ESP_SIZE $img
	mkfs.fat -F 32 -S 512 -n ESP $img > /dev/null
	mmd -i $img ::/EFI ::/EFI/BOOT ::/EFI/Linux
	[ "$UKI_LINUX_COPY" = 0 ] || mcopy -i $img $OUT/uki$sfx.efi ::/EFI/Linux/uki.efi
	mcopy -i $img $OUT/uki$sfx.efi ::/EFI/BOOT/bootaa64.efi
done
{
	echo "fingerprint $FP"
	echo "kernel $uname ($KDIR)"
	echo "userspace VENTUNO Q Buildroot $VQ_BUILD + overlay (modules${MODULES_ONLY:+ only}: $MODULES)"
	echo "test-definitions $TDREV"
	echo "cmdline $CMDLINE"
	if [ -n "$INITRD_DROP" ]; then
		echo "initrd $(stat -c %s $W/initrd) bytes ($INITRD_COMP, one archive, drop list $INITRD_DROP)"
	else
		echo "initrd $(stat -c %s $W/initrd) bytes (VENTUNO Q initramfs + gzip overlay archive)"
	fi
	[ -z "$INITRD_DROP" ] || cat $W/initrd-merge.txt
	echo "uki $(stat -c %s $OUT/uki.efi) bytes"
} > $OUT/build-info.txt
echo "$FP" > $OUT/FP
cd $OUT && sha256sum uki*.efi efi*.bin > SHA256SUMS
cat SHA256SUMS
