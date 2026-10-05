#!/bin/bash
set -euo pipefail
FP=${1:?fingerprint}
export CROSS_COMPILE=aarch64-linux-gnu-
OUT=/unoq/out/$FP
mkdir -p "$OUT"
J=$(nproc)

OB=/unoq/out/build-optee
rm -rf $OB
make -s -j$J -C /unoq/src-sr/optee_os O=$OB PLATFORM=qcom-agatti \
	CROSS_COMPILE64=aarch64-linux-gnu- \
	CFG_ARM64_core=y CFG_TEE_CORE_LOG_LEVEL=2 TEE_IMPL_VERSION=$FP
cp $OB/core/tee-raw.bin $OB/core/tee.elf "$OUT/"

UB=/unoq/out/build-u-boot
cd /unoq/src-sr/u-boot
make -s O=$UB qcom_defconfig tfa-optee.config arduino-uno-q.config
./scripts/config --file $UB/.config \
	--set-str LOCALVERSION "-$FP" --disable LOCALVERSION_AUTO
[ -n "${UBOOT_BOOTDELAY:-}" ] &&
	./scripts/config --file $UB/.config --set-val BOOTDELAY "$UBOOT_BOOTDELAY"
make -s O=$UB olddefconfig
make -s -j$J O=$UB
cp $UB/u-boot.bin $UB/.config "$OUT/"
mv "$OUT/.config" "$OUT/u-boot.config"

TB=/unoq/out/build-tfa
rm -rf $TB
cd /unoq/src-sr/tf-a
make -s -j$J PLAT=uno_q SPD=opteed BUILD_BASE=$TB BUILD_STRING=$FP \
	LOG_LEVEL=${TFA_LOG_LEVEL:-40} \
	BL32="$OUT/tee-raw.bin" BL33="$OUT/u-boot.bin" bl2 fip
cp $TB/uno_q/release/bl2/bl2.elf $TB/uno_q/release/bl31/bl31.elf \
	$TB/uno_q/release/fip.bin "$OUT/"
${CROSS_COMPILE}size -A "$OUT/bl2.elf" > "$OUT/bl2-size.txt"

cd "$OUT"
${CROSS_COMPILE}objcopy -I binary -B aarch64 -O elf64-littleaarch64 fip.bin fip.o
${CROSS_COMPILE}ld fip.o -o fip-unsigned.elf -EL -T /unoq/src-sr/tf-a/tools/qti/fip-elf.lds \
	--defsym=ELFENTRY=0x5f800000 -Ttext=0x5f800000
python3 /unoq/src-sr/qtestsign/qtestsign.py -v6 aboot -o fip.elf fip-unsigned.elf > /dev/null
rm -f fip.o fip-unsigned.elf
echo "$FP" > FP
for f in bl2.elf bl31.elf tee-raw.bin u-boot.bin fip.elf; do
	printf '%s: %s\n' "$f" "$(grep -ac "$FP" "$f")"
done
sha256sum bl2.elf bl31.elf tee-raw.bin u-boot.bin fip.bin fip.elf > SHA256SUMS
cat bl2-size.txt
