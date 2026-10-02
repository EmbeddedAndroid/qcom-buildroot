################################################################################
# kodiak.mk: build system for the Qualcomm RB3 Gen 2 (QCS6490, Kodiak)
#
# Boot sequence: XBL -> TF-A BL2 -> TF-A BL31 -> OP-TEE -> U-Boot -> Linux
# XBL loads TF-A BL2 from the tz partition into pIMEM and the uefi partition
# image to DDR at 0x9fc00000, then starts BL2 at EL3. BL2 loads BL31, OP-TEE
# (BL32) and U-Boot (BL33) from the FIP in that image. U-Boot boots the UKI on
# the ESP (efi partition) through UEFI.
#
# Outputs, in kodiak/output/:
#   bl2.elf     TF-A BL2, the TZ image before signing
#   tz.mbn      bl2.elf with a QTI signature (tz-qti-sign), flashed to tz_a
#               and tz_b
#   fip.elf     FIP (BL31 + OP-TEE + U-Boot) wrapped in an ELF loaded at
#               0x9fc00000 with a qtestsign test signature, flashed to
#               uefi_a and uefi_b
#   efi.bin     FAT32 ESP holding the UKI (kernel, DTB and the Buildroot
#               initramfs), flashed to efi
#
# XBL authenticates the TZ image with the QTI authenticator even when secure
# boot is disabled, so a qtestsign signature is not accepted for tz.mbn.
# tz-qti-sign signs bl2.elf through the QTI remote signing service (CASS);
# without access to it, place a signed tz.mbn in kodiak/input/ (see its
# README.md).
#
# TF-A BL31 on Kodiak links Qualcomm's QTISECLIB (libqtisec.a), the secure
# setup library coreboot publishes for SC7280; qtiseclib-fetch downloads the
# pinned release and checks its hash.
#
# Every invocation stamps BUILD_ID into each component it builds: the TF-A
# build string, the OP-TEE version, the U-Boot and Linux versions and the
# rootfs /etc/issue, so the console shows which build is running.
# kodiak/output/build-info.txt records the BUILD_ID of each output.
#
# Main targets
# -----------------------------------------------------------------------------
#   all            bootimage and efi
#   bootimage      bl2.elf and fip.elf (OP-TEE, U-Boot, TF-A)
#   tz-qti-sign    tz.mbn from bl2.elf (QTI remote signing, see above)
#   efi            efi.bin (Linux, Buildroot, UKI)
#   flash-loader   write tz.mbn to tz_a/tz_b and fip.elf to uefi_a/uefi_b
#   flash-kernel   write efi.bin to efi
#   flash-lava     flash-loader and flash-kernel on a LAVA lab board
#   clean          clean all components and kodiak/output/
#
# Component targets: optee-os, u-boot, tfa, fip, linux, linux-defconfig,
# buildroot, qtestsign-fetch, qtiseclib-fetch, and the matching *-clean
# targets.
#
# Configurable variables (command line or environment)
# -----------------------------------------------------------------------------
#   BUILD_ID          build identifier (default: kodiak-<UTC date-time>)
#   TF_A_FLAGS        TF-A make flags (default: PLAT=rb3gen2 SPD=opteed)
#   TF_A_DEBUG        1 for a TF-A debug build (default: 0)
#   QTISECLIB         libqtisec.a (default: kodiak/blobs/libqtisec.a, fetched)
#   U_BOOT_CONFIGS    U-Boot defconfig and config fragments
#   U_BOOT_DEVICE_TREE
#                     U-Boot device tree (default: qcom/qcs6490-rb3gen2)
#   LINUX_DEFCONFIG   kernel defconfig (default: defconfig)
#   LINUX_CMDLINE     kernel command line embedded in the UKI
#   FIREHOSE          UFS firehose programmer used by the flash targets
#                     (default: kodiak/input/prog_firehose_ddr.elf)
#   QDL, QDL_FLAGS    qdl binary and its options (default: --storage ufs)
#   FLASH_LAVA_CONNECT
#                     flash-lava: 1 interactive, 0 flash-only (default: ask
#                     on a terminal, else flash-only)
#   FLASH_LAVA_JOB    the LAVA job definition (default: kodiak/lava/flash-lava.yaml)
#   tz-qti-sign:      SECTOOLS, QTI_SIGN_DIR, SECURITY_PROFILE,
#                     CASS_CAPABILITY, QTI_SIGN_SERVER_URL,
#                     QTI_SIGN_SERVER_PORT (see the tz-qti-sign section)
################################################################################

################################################################################
# Platform
################################################################################
PLATFORM          = kodiak
OPTEE_OS_PLATFORM = qcom-kodiak

override COMPILE_NS_USER   := 64
override COMPILE_NS_KERNEL := 64
override COMPILE_S_USER    := 64
override COMPILE_S_KERNEL  := 64

# Evaluated once, so every component of an invocation gets the same value.
ifeq ($(origin BUILD_ID),undefined)
BUILD_ID := $(PLATFORM)-$(shell date -u +%y%m%d-%H%M%S)
endif

KODIAK_OUT   = $(CURDIR)/kodiak/output
KODIAK_IN    = $(CURDIR)/kodiak/input
KODIAK_BLOBS = $(CURDIR)/kodiak/blobs
BUILD_INFO   = $(KODIAK_OUT)/build-info.txt

################################################################################
# OP-TEE OS settings
################################################################################
# Info level: OP-TEE prints its version, which carries BUILD_ID, at boot.
# Set before the common.mk include so its ?= default (3) does not win.
CFG_TEE_CORE_LOG_LEVEL := 2

################################################################################
# Buildroot package selection
################################################################################
BR2_TARGET_GENERIC_GETTY_PORT := ttyMSM0
BR2_TARGET_GENERIC_ISSUE       = "OP-TEE embedded distrib for $(PLATFORM) ($(BUILD_ID))"
BR2_TARGET_ROOTFS_CPIO         = y
BR2_TARGET_ROOTFS_CPIO_GZIP    = y

# OP-TEE OS, TF-A, U-Boot and Linux are built outside of Buildroot; the
# OP-TEE client, xtest and examples come from the br-ext packages.
BR2_LINUX_KERNEL                = n
BR2_TARGET_ARM_TRUSTED_FIRMWARE = n
BR2_TARGET_OPTEE_OS             = n
BR2_TARGET_UBOOT                = n
BR2_PACKAGE_OPTEE_CLIENT        = n
BR2_PACKAGE_OPTEE_TEST          = n
BR2_PACKAGE_OPTEE_EXAMPLES      = n
BR2_PACKAGE_OPTEE_BENCHMARK     = n

# stress-ng loads the CPUs for the cpufreq checks.
BR2_PACKAGE_STRESS_NG           = y
# KVM: kvmtool and the KVM unit tests built for it, with their runner (bash)
# in /opt/kvm-unit-tests, and a small Linux guest (kernel and BusyBox
# initramfs) in /opt/kvm-guest. kvmtool reads console input only from a
# terminal; socat gives it a pty when a script drives the guest console.
BR2_PACKAGE_BUSYBOX_SHOW_OTHERS = y
BR2_PACKAGE_KVMTOOL             = y
BR2_PACKAGE_KVM_UNIT_TESTS_EXT  = y
BR2_PACKAGE_KVM_GUEST_EXT       = y
BR2_PACKAGE_SOCAT               = y

################################################################################
# Paths to repositories: the path= attributes in manifest.git/kodiak.xml.
# OPTEE_OS_PATH, UBOOT_PATH and LINUX_PATH come from common.mk.
################################################################################
TF_A_PATH ?= $(ROOT)/arm-trusted-firmware

include common.mk
include toolchain.mk

# common.mk passes CFG_IN_TREE_EARLY_TAS to OP-TEE on the make command line,
# which turns the Kodiak target.mk's '+= qcom_pas/...' into a no-op. Append
# the qcom_pas PAS TA here (after the include) so it is embedded as an early TA
# and advertised on the TEE bus, as the target configures it.
CFG_IN_TREE_EARLY_TAS += qcom_pas/cff7d191-7ca0-4784-af13-48223b9a4fbe

OPTEE_OS_COMMON_EXTRA_FLAGS += TEE_IMPL_VERSION=$(BUILD_ID)

# Buildroot rejects PATH entries containing spaces (Windows paths from WSL).
export PATH := $(shell echo "$$PATH" | tr ':' '\n' | grep -v ' ' | tr '\n' ':' | sed 's/:$$//')

################################################################################
# Top-level targets
################################################################################
.PHONY: all clean bootimage

all: bootimage efi

clean: optee-os-clean u-boot-clean tfa-clean linux-clean buildroot-clean
	rm -f $(KODIAK_OUT)/*.elf $(KODIAK_OUT)/*.mbn $(KODIAK_OUT)/*.bin \
	      $(KODIAK_OUT)/*.efi $(KODIAK_OUT)/*.dtb \
	      $(BUILD_INFO) $(KODIAK_OUT)/SHA256SUMS

$(KODIAK_OUT):
	mkdir -p $@

# record <output>: note the BUILD_ID the output was built with, replacing the
# line of an earlier build.
define record
	touch $(BUILD_INFO)
	sed -i '/^$(1) /d' $(BUILD_INFO)
	echo "$(1) $(BUILD_ID)" >> $(BUILD_INFO)
	$(sha256sums)
endef

OUTPUT_FILES = bl2.elf tz.mbn fip.elf efi.bin
sha256sums = cd $(KODIAK_OUT) && sha256sum $$(ls $(OUTPUT_FILES) 2>/dev/null) > SHA256SUMS

# id-of <output>: the BUILD_ID build-info.txt records for an output
id-of = $$(sed -n 's/^$(1) //p' $(BUILD_INFO))

.PHONY: help
help:
	@echo "Qualcomm RB3 Gen 2 (QCS6490, Kodiak) build system"
	@echo ""
	@echo "Boot flow: XBL -> TF-A BL2 (tz.mbn) -> BL31 -> OP-TEE -> U-Boot -> Linux"
	@echo ""
	@echo "Main targets:"
	@echo "  all            bootimage and efi"
	@echo "  bootimage      kodiak/output/bl2.elf and fip.elf"
	@echo "  tz-qti-sign    kodiak/output/tz.mbn from bl2.elf (QTI remote signing)"
	@echo "  efi            kodiak/output/efi.bin (kernel UKI + Buildroot rootfs)"
	@echo "  flash-loader   write tz.mbn and fip.elf over qdl (board in EDL)"
	@echo "  flash-kernel   write efi.bin over qdl (board in EDL)"
	@echo "  flash-lava     flash-loader and flash-kernel on a LAVA lab board"
	@echo "                 (asks: interactive with the serial console, or flash-only)"
	@echo "  clean          clean all components and kodiak/output/"
	@echo ""
	@echo "Component targets: optee-os u-boot tfa fip linux linux-defconfig"
	@echo "  buildroot qtestsign-fetch qtiseclib-fetch, and the matching *-clean targets"
	@echo ""
	@echo "Variables: BUILD_ID TF_A_FLAGS TF_A_DEBUG QTISECLIB U_BOOT_CONFIGS"
	@echo "  U_BOOT_DEVICE_TREE LINUX_DEFCONFIG LINUX_CMDLINE FIREHOSE QDL QDL_FLAGS"
	@echo "  FLASH_LAVA_CONNECT FLASH_LAVA_JOB;"
	@echo "  tz-qti-sign: SECTOOLS QTI_SIGN_DIR SECURITY_PROFILE CASS_CAPABILITY"
	@echo "  QTI_SIGN_SERVER_URL QTI_SIGN_SERVER_PORT"

################################################################################
# OP-TEE OS (BL32)
################################################################################
.PHONY: optee-os optee-os-clean

# Raw OP-TEE image, loaded by BL2 from the FIP.
BL32_BIN = $(OPTEE_OS_PATH)/out/arm/core/tee-raw.bin

optee-os: optee-os-common

optee-os-clean: optee-os-clean-common

################################################################################
# U-Boot (BL33): qcom_defconfig with the TF-A/OP-TEE fragment, built with the
# RB3 Gen 2 device tree. BL31 hands over no device tree, so U-Boot runs with
# the one it carries.
################################################################################
U_BOOT_CONFIGS     ?= qcom_defconfig tfa-optee.config
U_BOOT_DEVICE_TREE ?= qcom/qcs6490-rb3gen2
U_BOOT_OUTPUT       = $(UBOOT_PATH)/.output-kodiak
U_BOOT_BIN          = $(U_BOOT_OUTPUT)/u-boot.bin
U_BOOT_FLAGS        = -C $(UBOOT_PATH) O=$(U_BOOT_OUTPUT) \
		      CROSS_COMPILE="$(CCACHE)$(AARCH64_CROSS_COMPILE)"

.PHONY: u-boot u-boot-clean

u-boot:
	mkdir -p $(U_BOOT_OUTPUT)
	$(MAKE) $(U_BOOT_FLAGS) $(U_BOOT_CONFIGS)
	$(MAKE) $(U_BOOT_FLAGS) -j$(shell nproc) LOCALVERSION=-$(BUILD_ID) \
		DEVICE_TREE=$(U_BOOT_DEVICE_TREE)
	grep -aq '$(BUILD_ID)' $(U_BOOT_BIN) || \
		{ echo "ERROR: $(U_BOOT_BIN) lacks $(BUILD_ID)"; exit 1; }

u-boot-clean:
	rm -rf $(U_BOOT_OUTPUT)

################################################################################
# QTISECLIB: Qualcomm's secure setup library for SC7280 (QTISECLIB.CB.1.0
# release 00069), from the coreboot qc_blobs repository at a fixed commit,
# under its own license (LICENSE next to it in qc_blobs). TF-A BL31 links it
# for the rb3gen2 platform; without it TF-A builds a stub that does not boot.
################################################################################
QTISECLIB_REV    = 33cc4f2fd8d9529c4231564d7a30a00c06b213de
QTISECLIB_URL    = https://raw.githubusercontent.com/coreboot/qc_blobs/$(QTISECLIB_REV)/sc7280/qtiseclib
QTISECLIB_SHA256 = 6860dda0701c8709530608cc0e5a61b76484ae16cb673ba9a23510cf4b3d57bf
QTISECLIB       ?= $(KODIAK_BLOBS)/libqtisec.a

.PHONY: qtiseclib-fetch qtiseclib-clean

qtiseclib-fetch:
	@if [ ! -f $(QTISECLIB) ]; then \
		mkdir -p $(dir $(QTISECLIB)) && \
		for f in libqtisec.a LICENSE Release_Notes.txt; do \
			curl --retry 5 -fsSL -o $(dir $(QTISECLIB))$$f $(QTISECLIB_URL)/$$f || exit 1; \
		done; \
	fi
	echo "$(QTISECLIB_SHA256)  $(QTISECLIB)" | sha256sum -c

qtiseclib-clean:
	rm -rf $(KODIAK_BLOBS)

################################################################################
# TF-A: BL2 (the TZ image) and the FIP (BL31 + BL32 + BL33)
################################################################################
TF_A_FLAGS ?= PLAT=rb3gen2 SPD=opteed
TF_A_DEBUG ?= 0
TF_A_BUILD  = $(TF_A_PATH)/build/rb3gen2/$(if $(filter 1,$(TF_A_DEBUG)),debug,release)

.PHONY: tfa tfa-clean

# TF-A does not rebuild when only BUILD_STRING changes; drop the objects that
# embed it so each build carries its own BUILD_ID.
tfa: optee-os u-boot qtiseclib-fetch | $(KODIAK_OUT)
	rm -f $(TF_A_BUILD)/bl2/bl_common.o $(TF_A_BUILD)/bl2/bl2_main.o \
	      $(TF_A_BUILD)/bl31/bl_common.o $(TF_A_BUILD)/bl31/bl31_main.o
	CROSS_COMPILE="$(AARCH64_CROSS_COMPILE)" $(MAKE) -C $(TF_A_PATH) \
		-j$(shell nproc) $(TF_A_FLAGS) DEBUG=$(TF_A_DEBUG) \
		QTISECLIB_PATH=$(QTISECLIB) BUILD_STRING=$(BUILD_ID) \
		BL32=$(BL32_BIN) BL33=$(U_BOOT_BIN) fip all
	cp $(TF_A_BUILD)/bl2/bl2.elf $(KODIAK_OUT)/bl2.elf
	grep -aq '$(BUILD_ID)' $(KODIAK_OUT)/bl2.elf || \
		{ echo "ERROR: bl2.elf lacks $(BUILD_ID)"; exit 1; }
	$(call record,bl2.elf)

tfa-clean:
	CROSS_COMPILE="$(AARCH64_CROSS_COMPILE)" $(MAKE) -C $(TF_A_PATH) \
		$(TF_A_FLAGS) DEBUG=$(TF_A_DEBUG) clean

################################################################################
# fip.elf: XBL loads the uefi partition image as an ELF with an OEM
# signature, so the FIP is wrapped in an ELF loaded at 0x9fc00000 and signed
# with qtestsign by TF-A's generate_fip_elf.sh. The script works in the
# current directory and uses ./qtestsign.
################################################################################
QTESTSIGN_PATH ?= $(ROOT)/qtestsign
FIP_LOAD_ADDR  ?= 0x9fc00000
FIP_WORK        = $(KODIAK_OUT)/.fip

.PHONY: qtestsign-fetch fip

qtestsign-fetch:
	@if [ ! -d $(QTESTSIGN_PATH) ]; then \
		echo "Cloning qtestsign..."; \
		git clone https://github.com/msm8916-mainline/qtestsign $(QTESTSIGN_PATH); \
	fi

fip: tfa qtestsign-fetch
	rm -rf $(FIP_WORK) && mkdir -p $(FIP_WORK)
	ln -s $(QTESTSIGN_PATH) $(FIP_WORK)/qtestsign
	cd $(FIP_WORK) && CROSS_COMPILE="$(AARCH64_CROSS_COMPILE)" \
		$(TF_A_PATH)/tools/qti/generate_fip_elf.sh $(TF_A_BUILD)/fip.bin $(FIP_LOAD_ADDR)
	mv $(FIP_WORK)/fip.elf $(KODIAK_OUT)/fip.elf
	rm -rf $(FIP_WORK)
	@# BL31, OP-TEE and U-Boot each carry BUILD_ID.
	[ $$(grep -ac '$(BUILD_ID)' $(KODIAK_OUT)/fip.elf) -ge 3 ] || \
		{ echo "ERROR: fip.elf lacks $(BUILD_ID) in BL31, OP-TEE or U-Boot"; exit 1; }
	$(call record,fip.elf)

# A tz.mbn signed from an earlier bl2.elf no longer matches; tz-qti-sign
# makes a new one.
bootimage: fip
	rm -f $(KODIAK_OUT)/tz.mbn
	sed -i '/^tz.mbn /d' $(BUILD_INFO)

################################################################################
# tz-qti-sign: tz.mbn from bl2.elf
#
# sectools signs bl2.elf as a TZ image through the QTI remote signing service
# and validates it. Kodiak takes no SWIV segment. sectools, the Kodiak TZ
# security profile and a CASS capability come from the Qualcomm signing
# package and account; none of them is needed to build.
################################################################################
SECTOOLS             ?= sectools
QTI_SIGN_DIR         ?=
SECURITY_PROFILE     ?= $(QTI_SIGN_DIR)/kodiak_tz_security_profile.xml
CASS_CAPABILITY      ?=
QTI_SIGN_SERVER_URL  ?=
QTI_SIGN_SERVER_PORT ?=

.PHONY: tz-qti-sign

# require-var <name>: fail unless the variable is set
require-var = [ -n "$($(1))" ] || { echo "ERROR: set $(1) for QTI remote signing"; exit 1; }

tz-qti-sign:
	@$(call require-var,CASS_CAPABILITY)
	@$(call require-var,QTI_SIGN_SERVER_URL)
	@$(call require-var,QTI_SIGN_SERVER_PORT)
	@[ -f "$(SECURITY_PROFILE)" ] || \
		{ echo "ERROR: $(SECURITY_PROFILE) missing: set QTI_SIGN_DIR or SECURITY_PROFILE"; exit 1; }
	@[ -f $(KODIAK_OUT)/bl2.elf ] || \
		{ echo "ERROR: kodiak/output/bl2.elf missing: run 'make bootimage' first"; exit 1; }
	$(SECTOOLS) secure-image $(KODIAK_OUT)/bl2.elf \
		--outfile $(KODIAK_OUT)/tz.mbn.tmp \
		--image-id TZ \
		--security-profile $(SECURITY_PROFILE) \
		--qti --sign --signing-mode QTI-REMOTE \
		--cass-capability $(CASS_CAPABILITY) \
		--qti-remote-signing-server-url $(QTI_SIGN_SERVER_URL) \
		--qti-remote-signing-server-port $(QTI_SIGN_SERVER_PORT)
	$(SECTOOLS) secure-image $(KODIAK_OUT)/tz.mbn.tmp --validate --qti \
		--image-id TZ --security-profile $(SECURITY_PROFILE)
	mv $(KODIAK_OUT)/tz.mbn.tmp $(KODIAK_OUT)/tz.mbn
	id=$(call id-of,bl2.elf) && \
		sed -i '/^tz.mbn /d' $(BUILD_INFO) && \
		echo "tz.mbn $$id" >> $(BUILD_INFO)
	$(sha256sums)

################################################################################
# Linux kernel
#
# linux-defconfig applies LINUX_DEFCONFIG and the options below; linux runs it
# when there is no .config. The kernel has no modules, so everything the
# board needs is built in.
#
# LINUX_TEST_CONFIGS: MEMTEST, the early memory test that memtest=<N> on the
# kernel command line runs (N patterns over all free memory). linux fails if
# it is not built in.
################################################################################
LINUX_TEST_CONFIGS = MEMTEST
LINUX_EXPORTS    = ARCH=arm64 CROSS_COMPILE="$(CCACHE)$(AARCH64_CROSS_COMPILE)"
LINUX_DEFCONFIG ?= defconfig
# Linux runs at EL2 with no hypervisor underneath: the Kodiak EL2 overlay,
# applied by the kernel build, hands it the resources a hypervisor would own.
LINUX_DT         = qcs6490-rb3gen2-el2
LINUX_DTB        = $(KODIAK_OUT)/$(LINUX_DT).dtb
LINUX_IMAGE      = $(LINUX_PATH)/arch/arm64/boot/vmlinuz.efi

.PHONY: linux-defconfig linux linux-clean

linux-defconfig:
	$(LINUX_EXPORTS) $(MAKE) -C $(LINUX_PATH) mrproper
	$(LINUX_EXPORTS) $(MAKE) -C $(LINUX_PATH) $(LINUX_DEFCONFIG)
	$(LINUX_EXPORTS) $(LINUX_PATH)/scripts/config --file $(LINUX_PATH)/.config \
		-e TEE \
		-e OPTEE \
		-d QCOMTEE \
		-e DEVTMPFS \
		-e EFI \
		-e EFI_STUB \
		-e EFI_ZBOOT \
		-e VIRTUALIZATION \
		-e KVM \
		-d LOCALVERSION_AUTO \
		-d MODULES \
		$(addprefix -e ,$(LINUX_TEST_CONFIGS))
	$(LINUX_EXPORTS) $(MAKE) -C $(LINUX_PATH) olddefconfig

linux: | $(KODIAK_OUT)
	@if [ ! -f $(LINUX_PATH)/.config ]; then \
		$(MAKE) -f $(firstword $(MAKEFILE_LIST)) linux-defconfig; \
	fi
	@for c in $(LINUX_TEST_CONFIGS); do \
		grep -qx "CONFIG_$$c=y" $(LINUX_PATH)/.config || \
		{ echo "ERROR: CONFIG_$$c is not built in: run 'make linux-defconfig'"; exit 1; }; \
	done
	$(LINUX_EXPORTS) $(MAKE) -C $(LINUX_PATH) -j$(shell nproc) \
		LOCALVERSION=-$(BUILD_ID) Image vmlinuz.efi qcom/$(LINUX_DT).dtb
	grep -q -- '-$(BUILD_ID)$$' $(LINUX_PATH)/include/config/kernel.release || \
		{ echo "ERROR: the kernel release lacks $(BUILD_ID)"; exit 1; }
	cp $(LINUX_PATH)/arch/arm64/boot/dts/qcom/$(LINUX_DT).dtb $(LINUX_DTB)

linux-clean:
	$(LINUX_EXPORTS) $(MAKE) -C $(LINUX_PATH) clean
	rm -f $(LINUX_DTB)

################################################################################
# UKI and ESP (efi.bin)
#
# ukify bundles the kernel, the DTB, the Buildroot initramfs and the command
# line into one EFI binary. efi.bin is a FAT32 image holding it both as
# EFI/Linux/uki.efi and as the removable-media fallback EFI/BOOT/bootaa64.efi,
# which U-Boot's bootefi bootmgr starts. 4096-byte sectors match the UFS
# block size; the volume fills the 512 MiB efi partition.
#
# Host dependencies: systemd-ukify mtools dosfstools
################################################################################
BR_INITRAMFS  = $(ROOT)/out-br/images/rootfs.cpio.gz
EFI_BIN_SIZE ?= 512M

LINUX_CMDLINE ?= \
	root=/dev/ram0 rw \
	console=ttyMSM0,115200 earlycon \
	qcom_scm.download_mode=1

.PHONY: efi efi-clean

efi: linux buildroot | $(KODIAK_OUT)
	grep -q '$(BUILD_ID)' $(ROOT)/out-br/target/etc/issue || \
		{ echo "ERROR: the rootfs /etc/issue lacks $(BUILD_ID)"; exit 1; }
	rm -f $(KODIAK_OUT)/uki.efi $(KODIAK_OUT)/efi.bin
	ukify build \
		--linux=$(LINUX_IMAGE) \
		--initrd=$(BR_INITRAMFS) \
		--cmdline='$(LINUX_CMDLINE)' \
		--efi-arch=aa64 \
		--stub=$(CURDIR)/qcom/ukify/linuxaa64.efi.stub \
		--os-release=@/etc/os-release \
		--devicetree=$(LINUX_DTB) \
		--output=$(KODIAK_OUT)/uki.efi
	truncate -s $(EFI_BIN_SIZE) $(KODIAK_OUT)/efi.bin
	mkfs.fat -F 32 -S 4096 $(KODIAK_OUT)/efi.bin
	mmd -i $(KODIAK_OUT)/efi.bin ::/EFI ::/EFI/BOOT ::/EFI/Linux
	mcopy -i $(KODIAK_OUT)/efi.bin $(KODIAK_OUT)/uki.efi ::/EFI/Linux/uki.efi
	mcopy -i $(KODIAK_OUT)/efi.bin $(KODIAK_OUT)/uki.efi ::/EFI/BOOT/bootaa64.efi
	$(call record,efi.bin)

efi-clean:
	rm -f $(KODIAK_OUT)/uki.efi $(KODIAK_OUT)/efi.bin

################################################################################
# Flashing over qdl (https://github.com/linux-msm/qdl) with the board in EDL
# mode. The RB3 Gen 2 boots from UFS; only the tz and uefi partitions (LUN 4)
# and the efi partition (LUN 0) are written, so XBL and the rest of the stock
# firmware stay in place. Both A and B slots are written so the boot chain
# cannot fall back to the stock images.
#
# FIREHOSE is the UFS firehose programmer shipped with the board software.
# tz.mbn comes from kodiak/output/ (tz-qti-sign) or, when there is none, from
# kodiak/input/. A tz.mbn from tz-qti-sign has to come from the build that
# made fip.elf.
################################################################################
FIREHOSE  ?= $(KODIAK_IN)/prog_firehose_ddr.elf
QDL       ?= qdl
QDL_FLAGS ?= --storage ufs
TZ_MBN     = $(firstword $(wildcard $(KODIAK_OUT)/tz.mbn $(KODIAK_IN)/tz.mbn))

.PHONY: flash-loader flash-kernel

# The inputs of flash-loader and flash-kernel (and flash-lava).
define check-loader
	@[ -f "$(FIREHOSE)" ] || \
		{ echo "ERROR: firehose programmer $(FIREHOSE) missing (see kodiak/input/README.md)"; exit 1; }
	@[ -n "$(TZ_MBN)" ] || \
		{ echo "ERROR: no tz.mbn: run 'make tz-qti-sign' or place a signed tz.mbn in kodiak/input/"; exit 1; }
	@[ -f $(KODIAK_OUT)/fip.elf ] || \
		{ echo "ERROR: kodiak/output/fip.elf missing: run 'make bootimage' first"; exit 1; }
	@[ "$(TZ_MBN)" != "$(KODIAK_OUT)/tz.mbn" ] || \
		{ [ -n "$(call id-of,tz.mbn)" ] && \
		  [ "$(call id-of,tz.mbn)" = "$(call id-of,fip.elf)" ]; } || \
		{ echo "ERROR: tz.mbn and fip.elf are from different builds (see $(BUILD_INFO))"; exit 1; }
endef

define check-kernel
	@[ -f "$(FIREHOSE)" ] || \
		{ echo "ERROR: firehose programmer $(FIREHOSE) missing (see kodiak/input/README.md)"; exit 1; }
	@[ -f $(KODIAK_OUT)/efi.bin ] || \
		{ echo "ERROR: kodiak/output/efi.bin missing: run 'make efi' first"; exit 1; }
endef

flash-loader:
	$(check-loader)
	$(QDL) $(QDL_FLAGS) $(FIREHOSE) \
		write tz_a $(TZ_MBN) write tz_b $(TZ_MBN) \
		write uefi_a $(KODIAK_OUT)/fip.elf write uefi_b $(KODIAK_OUT)/fip.elf

flash-kernel:
	$(check-kernel)
	$(QDL) $(QDL_FLAGS) $(FIREHOSE) write efi $(KODIAK_OUT)/efi.bin

################################################################################
# flash-lava: flash a board in the LAVA lab (https://lava.infra.foundries.io,
# device type qcs6490-rb3gen2) instead of one on USB
#
# LAVA fetches a flat qcomflash tarball over HTTP and runs qdl next to the
# board (deploy to qdl, boot method qdl, storage ufs). flash-lava writes what
# flash-loader and flash-kernel write: tz_a, tz_b, uefi_a, uefi_b and efi.
# LAVA passes qdl rawprogram files, not partition names, so the tarball
# carries rawprogram0.xml (LUN 0) and rawprogram4.xml (LUN 4) with the sectors
# of those partitions in the RB3 Gen 2 UFS layout (qcom-ptool
# platforms/qcs6490-rb3gen2/ufs, which the board's stock image writes), and
# empty patch files. qcom/lava/submit.sh then uploads the tarball and flashes
# a board, either interactively (qcom/lava/connect.sh reserves a board,
# flashes it and opens its serial console; Ctrl+D releases it) or with a
# one-shot job that boots it to a login prompt (FLASH_LAVA_CONNECT=0, the
# default without a terminal). flash-lava-package only builds the tarball.
# See qcom/lava/README.md.
################################################################################
FLASH_LAVA_DIR     = $(KODIAK_OUT)/flash-lava
FLASH_LAVA_TARBALL = $(KODIAK_OUT)/kodiak-flash.qcomflash.tar.gz
FLASH_LAVA_JOB    ?= $(CURDIR)/kodiak/lava/flash-lava.yaml
FLASH_LAVA_SUBMIT  = $(CURDIR)/qcom/lava/submit.sh

# <LUN>:<partition>:<first sector>:<sectors>:<image>, 4096-byte sectors
FLASH_LAVA_PARTS = \
	4:uefi_a:17094:1280:fip.elf 4:tz_a:18374:1024:tz.mbn \
	4:uefi_b:39970:1280:fip.elf 4:tz_b:41250:1024:tz.mbn \
	0:efi:6:131072:efi.bin

.PHONY: flash-lava flash-lava-package

flash-lava: flash-lava-package
	$(FLASH_LAVA_SUBMIT) $(FLASH_LAVA_TARBALL) $(FLASH_LAVA_JOB)

flash-lava-package:
	$(check-loader)
	$(check-kernel)
	rm -rf $(FLASH_LAVA_DIR)
	mkdir -p $(FLASH_LAVA_DIR)
	cp $(FIREHOSE) $(FLASH_LAVA_DIR)/prog_firehose_ddr.elf
	cp $(TZ_MBN) $(FLASH_LAVA_DIR)/tz.mbn
	cp $(KODIAK_OUT)/fip.elf $(KODIAK_OUT)/efi.bin $(FLASH_LAVA_DIR)/
	cd $(FLASH_LAVA_DIR) && for lun in 0 4; do { \
		echo '<?xml version="1.0" ?>'; \
		echo '<data>'; \
		for p in $(FLASH_LAVA_PARTS); do \
			set -- $$(echo $$p | tr : ' '); \
			[ $$1 = $$lun ] || continue; \
			[ $$(stat -c %s $$5) -le $$(($$4 * 4096)) ] || \
				{ echo "ERROR: $$5 does not fit in $$2" >&2; exit 1; }; \
			echo "  <program SECTOR_SIZE_IN_BYTES=\"4096\" file_sector_offset=\"0\" filename=\"$$5\" label=\"$$2\" num_partition_sectors=\"$$4\" physical_partition_number=\"$$1\" sparse=\"false\" start_sector=\"$$3\"/>"; \
		done; \
		echo '</data>'; \
	} > rawprogram$$lun.xml || exit 1; \
	printf '<?xml version="1.0" ?>\n<patches>\n</patches>\n' > patch$$lun.xml; done
	tar -czf $(FLASH_LAVA_TARBALL) -C $(FLASH_LAVA_DIR) .
	@echo "LAVA flash tarball: $(FLASH_LAVA_TARBALL)"
