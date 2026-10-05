#!/bin/bash
set -euo pipefail
FP=${1:?fingerprint}
SRC=/unoq/src-sr/linux
DTBS="qcom/qrb2210-arduino-imola.dtb qcom/qrb2210-arduino-imola-el2.dtb"
KB=/unoq/out/build-linux-venus
OUT=/unoq/out/$FP/linux
export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
J=$(nproc)
mkdir -p "$OUT"

cat /unoq/src-sr/linux.revision

mkdir -p $KB
cp /unoq/build/linux/r52-kernel.config $KB/.config
$SRC/scripts/config --file $KB/.config \
	--set-str LOCALVERSION "-$FP" --disable LOCALVERSION_AUTO \
	--enable MEMTEST --enable IKCONFIG --enable IKCONFIG_PROC \
	--enable QCOM_PAS_TEE --disable ARM_SMCCC_SOC_ID --enable QCOM_SOCINFO
make -s -C $SRC O=$KB olddefconfig
! grep -q '^CONFIG_ARM_SMCCC_SOC_ID=' $KB/.config || { echo "ARM_SMCCC_SOC_ID is set"; exit 1; }
grep -qx 'CONFIG_QCOM_SOCINFO=y' $KB/.config || { echo "QCOM_SOCINFO is not built in"; exit 1; }
make -s -C $SRC O=$KB -j$J Image modules 2>&1 | tee $KB/build.log
# One DTB goal per make: two composite DTBs sharing a base race otherwise.
for d in $DTBS; do make -s -C $SRC O=$KB -j$J $d; done
rm -rf $KB/mods
make -s -C $SRC O=$KB INSTALL_MOD_PATH=$KB/mods INSTALL_MOD_STRIP=1 modules_install

cp $KB/arch/arm64/boot/Image "$OUT/"
for d in $DTBS; do cp $KB/arch/arm64/boot/dts/$d "$OUT/"; done
cp $KB/.config "$OUT/kernel.config"
make -s -C $SRC O=$KB kernelrelease > "$OUT/kernel.release"
tar -C $KB/mods -czf "$OUT/modules.tar.gz" lib/modules
cp /unoq/src-sr/linux.revision "$OUT/series.txt"
cd "$OUT"
echo "WARNINGS $(grep -c 'warning:' $KB/build.log)"
grep -ac "$FP" Image
sha256sum Image *.dtb kernel.config modules.tar.gz > SHA256SUMS
cat kernel.release
