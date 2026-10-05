#!/bin/bash
set -euo pipefail
board=${1:?board}
id=${2:?fresh fingerprint}
case $board in
vq) platform=monaco ;;
kodiak|lemans) platform=$board ;;
*) exit 2 ;;
esac
ws=/monza/qb/$platform-sr
out=/monza/out/qcom-buildroot/$id
log=/monza/logs/sr-$board-$id.log
mkdir -p /monza/logs
exec >"$log" 2>&1
trap 'rc=$?; echo "FINAL-EXIT $rc"' EXIT
export GIT_COMMITTER_NAME='Tyler Baker'
export GIT_COMMITTER_EMAIL=tyler.baker@oss.qualcomm.com
export GIT_AUTHOR_NAME="$GIT_COMMITTER_NAME"
export GIT_AUTHOR_EMAIL="$GIT_COMMITTER_EMAIL"
echo "START $(date -u +%FT%TZ) $board $id"
bash /monza/qb-tools/vm-workspace.sh "$platform" integration-20261005-sr "$platform-sr"
python3 "$ws/build/qcom/systemready/prepare.py" "$board" "$ws" /monza/sr/bundles
cd "$ws/build"
echo 'STAGE toolchains'
make toolchains
echo 'STAGE linux-defconfig'
make linux-defconfig
if [ "$board" = lemans ]; then
    ../linux/scripts/config --file ../linux/.config -e MEMTEST
    cc=$(compgen -G "$ws/toolchains/aarch64/bin/aarch64-*-gcc" | head -1)
    make -C ../linux ARCH=arm64 CROSS_COMPILE="${cc%gcc}" olddefconfig
fi
echo 'STAGE build'
if [ "$board" = lemans ]; then
    fpvars=("TEE_IMPL_VERSION=$id" CFG_TEE_CORE_LOG_LEVEL=2 "LOCALVERSION=-$id"
        "TF_A_FLAGS=PLAT=lemans_evk SPD=opteed BUILD_STRING=$id"
        "BR2_TARGET_GENERIC_ISSUE=\"OP-TEE embedded distrib for lemans ($id)\""
        BR2_PACKAGE_BUSYBOX_SHOW_OTHERS=y BR2_PACKAGE_KVMTOOL=y
        BR2_PACKAGE_KVM_UNIT_TESTS_EXT=y BR2_PACKAGE_KVM_GUEST_EXT=y BR2_PACKAGE_SOCAT=y)
    make bootimage "${fpvars[@]}"
    make efi "${fpvars[@]}" LINUX_CMDLINE='console=ttyMSM0,115200 qcom_scm.download_mode=1 arm-smmu.disable_bypass=0 clk_ignore_unused pd_ignore_unused'
else
    make all BUILD_ID="$id"
fi
echo 'STAGE collect'
mkdir -p "$out"
cp -a "$platform/output/." "$out/"
rm -rf "$out/.fip" "$out/.uefi" "$out/edl-package" "$out/edl-bootloader" "$out/modules" "$out/flash-lava"
cp "$ws/manifest-pinned.xml" "$out/"
cp qcom/systemready/sources.json "$out/source-pins.json"
for p in build linux u-boot arm-trusted-firmware optee_os optee_test buildroot; do
    echo "$p $(git -C "$ws/$p" rev-parse HEAD) $(git -C "$ws/$p" status --porcelain | wc -l) changed"
done > "$out/sources.txt"
cp "$ws/linux/.config" "$out/kernel.config"
cp "$ws/out-br/.config" "$out/buildroot.config"
cat "$ws/linux/include/config/kernel.release" > "$out/kernel.release"
cp "$ws/out-br/target/etc/issue" "$out/issue.txt"
ls "$ws/out-br/build" > "$out/br-packages.txt"
find "$ws/out-br/target" -type f -printf '%P\n' | sort > "$out/rootfs-files.txt"
if [ "$board" = lemans ]; then
    cp lemans/blobs/linux-firmware/qcom/sa8775p/qupv3fw.elf "$out/"
fi
for f in "$out"/*.elf "$out"/*.mbn; do
    [ -e "$f" ] || continue
    echo "FP $(basename "$f") $(grep -ac "$id" "$f" || true)"
done
(cd "$out" && find . -maxdepth 1 -type f \( -name "*.elf" -o -name "*.mbn" -o -name "efi.bin" \) -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS.flash)
grep -q "$id" "$out/kernel.release"
grep -q "$id" "$out/issue.txt"
echo "END $(date -u +%FT%TZ)"
