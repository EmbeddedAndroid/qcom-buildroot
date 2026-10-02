################################################################################
# agatti.mk: build system for the Arduino UNO Q (Qualcomm QRB2210, Agatti)
#
# Boot sequence: XBL -> TF-A BL2 -> TF-A BL31 -> OP-TEE -> U-Boot -> Linux
# XBL loads TF-A BL2 from the tz partition into the IMEM TZ window and the
# uefi partition image to DDR at 0x5f800000, then starts BL2 at EL3. BL2
# loads BL31, OP-TEE (BL32) and U-Boot (BL33) from the FIP in that image.
# U-Boot boots the UKI on the ESP (efi partition) through UEFI.
#
# Outputs, in agatti/output/:
#   bl2.elf     TF-A BL2, the TZ image before signing
#   tz.mbn      bl2.elf with a QTI signature (tz-qti-sign), flashed to tz_a
#               and tz_b
#   fip.elf     FIP (BL31 + OP-TEE + U-Boot) wrapped in an ELF loaded at
#               0x5f800000 with a qtestsign test signature, flashed to
#               uefi_a and uefi_b
#   efi.bin     FAT32 ESP holding the UKI (kernel, DTB and the Buildroot
#               initramfs), flashed to efi
#
# XBL authenticates the TZ image with the QTI authenticator even when secure
# boot is disabled, so a qtestsign signature is not accepted for tz.mbn.
# tz-qti-sign signs bl2.elf through the QTI remote signing service (CASS);
# without access to it, place a signed tz.mbn in agatti/input/ (see its
# README.md).
#
# Every invocation stamps BUILD_ID into each component it builds: the TF-A
# build string, the OP-TEE version, the U-Boot and Linux versions and the
# rootfs /etc/issue, so the console shows which build is running.
# agatti/output/build-info.txt records the BUILD_ID of each output.
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
#   clean          clean all components and agatti/output/
#
# Component targets: optee-os, u-boot, tfa, fip, linux, linux-defconfig,
# linux-patches, linux-modules, buildroot, qtestsign-fetch, video-streams, and
# the matching *-clean targets.
#
# Configurable variables (command line or environment)
# -----------------------------------------------------------------------------
#   BUILD_ID          build identifier (default: agatti-<UTC date-time>)
#   TF_A_FLAGS        TF-A make flags (default: PLAT=uno_q SPD=opteed)
#   TF_A_DEBUG        1 for a TF-A debug build (default: 0)
#   U_BOOT_CONFIGS    U-Boot defconfig and config fragments
#   LINUX_CONFIG      kernel configuration (default: agatti/linux.config)
#   LINUX_CMDLINE     kernel command line embedded in the UKI
#   FIREHOSE          eMMC firehose programmer used by the flash targets
#                     (default: agatti/input/prog_firehose_ddr.elf)
#   QDL, QDL_FLAGS    qdl binary and its options (default: --storage emmc)
#   FLASH_LAVA_CONNECT
#                     flash-lava: 1 interactive, 0 flash-only (default: ask
#                     on a terminal, else flash-only)
#   FLASH_LAVA_JOB    the LAVA job definition (default: agatti/lava/flash-lava.yaml)
#   QCOM_VIDEO_TEST   y to put FFmpeg and the video-codec test streams in
#                     the rootfs (default: y; see qcom/video/video.mk)
#   tz-qti-sign:      SECTOOLS, QTI_SIGN_DIR, SECURITY_PROFILE,
#                     CASS_CAPABILITY, QTI_SIGN_SERVER_URL,
#                     QTI_SIGN_SERVER_PORT (see the tz-qti-sign section)
################################################################################

################################################################################
# Platform
################################################################################
PLATFORM          = agatti
OPTEE_OS_PLATFORM = qcom-agatti

override COMPILE_NS_USER   := 64
override COMPILE_NS_KERNEL := 64
override COMPILE_S_USER    := 64
override COMPILE_S_KERNEL  := 64

# Evaluated once, so every component of an invocation gets the same value.
ifeq ($(origin BUILD_ID),undefined)
BUILD_ID := $(PLATFORM)-$(shell date -u +%y%m%d-%H%M%S)
endif

AGATTI_OUT = $(CURDIR)/agatti/output
AGATTI_IN  = $(CURDIR)/agatti/input
BUILD_INFO = $(AGATTI_OUT)/build-info.txt

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
# The kernel modules and the S05modules init script that loads some at boot
# (see linux-modules).
BR2_ROOTFS_OVERLAY              = $(CURDIR)/agatti/overlay $(LINUX_MODULES_DIR)

################################################################################
# Paths to repositories: the path= attributes in manifest.git/agatti.xml.
# OPTEE_OS_PATH, UBOOT_PATH and LINUX_PATH come from common.mk.
################################################################################
TF_A_PATH ?= $(ROOT)/arm-trusted-firmware

include common.mk
include toolchain.mk

# FFmpeg and the reference streams of the video-codec test (qcom/video).
QCOM_VIDEO_TEST ?= y
include qcom/video/video.mk

OPTEE_OS_COMMON_EXTRA_FLAGS += TEE_IMPL_VERSION=$(BUILD_ID)

# Buildroot rejects PATH entries containing spaces (Windows paths from WSL).
export PATH := $(shell echo "$$PATH" | tr ':' '\n' | grep -v ' ' | tr '\n' ':' | sed 's/:$$//')

################################################################################
# Top-level targets
################################################################################
.PHONY: all clean bootimage

all: bootimage efi

clean: optee-os-clean u-boot-clean tfa-clean linux-clean buildroot-clean
	rm -f $(AGATTI_OUT)/*.elf $(AGATTI_OUT)/*.mbn $(AGATTI_OUT)/*.bin \
	      $(AGATTI_OUT)/*.efi $(AGATTI_OUT)/*.dtb \
	      $(BUILD_INFO) $(AGATTI_OUT)/SHA256SUMS

$(AGATTI_OUT):
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
sha256sums = cd $(AGATTI_OUT) && sha256sum $$(ls $(OUTPUT_FILES) 2>/dev/null) > SHA256SUMS

# id-of <output>: the BUILD_ID build-info.txt records for an output
id-of = $$(sed -n 's/^$(1) //p' $(BUILD_INFO))

.PHONY: help
help:
	@echo "Arduino UNO Q (Qualcomm QRB2210, Agatti) build system"
	@echo ""
	@echo "Boot flow: XBL -> TF-A BL2 (tz.mbn) -> BL31 -> OP-TEE -> U-Boot -> Linux"
	@echo ""
	@echo "Main targets:"
	@echo "  all            bootimage and efi"
	@echo "  bootimage      agatti/output/bl2.elf and fip.elf"
	@echo "  tz-qti-sign    agatti/output/tz.mbn from bl2.elf (QTI remote signing)"
	@echo "  efi            agatti/output/efi.bin (kernel UKI + Buildroot rootfs)"
	@echo "  flash-loader   write tz.mbn and fip.elf over qdl (board in EDL)"
	@echo "  flash-kernel   write efi.bin over qdl (board in EDL)"
	@echo "  flash-lava     flash-loader and flash-kernel on a LAVA lab board"
	@echo "                 (asks: interactive with the serial console, or flash-only)"
	@echo "  clean          clean all components and agatti/output/"
	@echo ""
	@echo "Component targets: optee-os u-boot tfa fip linux linux-defconfig"
	@echo "  linux-patches linux-modules buildroot qtestsign-fetch, and the matching"
	@echo "  *-clean targets"
	@echo ""
	@echo "Variables: BUILD_ID TF_A_FLAGS TF_A_DEBUG U_BOOT_CONFIGS LINUX_CONFIG"
	@echo "  LINUX_CMDLINE FIREHOSE QDL QDL_FLAGS FLASH_LAVA_CONNECT FLASH_LAVA_JOB;"
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
# U-Boot (BL33): qcom_defconfig with the TF-A/OP-TEE and board fragments. The
# board fragment sets the qrb2210-arduino-imola device tree.
################################################################################
U_BOOT_CONFIGS ?= qcom_defconfig tfa-optee.config arduino-uno-q.config
U_BOOT_OUTPUT   = $(UBOOT_PATH)/.output-agatti
U_BOOT_BIN      = $(U_BOOT_OUTPUT)/u-boot.bin
U_BOOT_FLAGS    = -C $(UBOOT_PATH) O=$(U_BOOT_OUTPUT) \
		  CROSS_COMPILE="$(CCACHE)$(AARCH64_CROSS_COMPILE)"

.PHONY: u-boot u-boot-clean

u-boot:
	mkdir -p $(U_BOOT_OUTPUT)
	$(MAKE) $(U_BOOT_FLAGS) $(U_BOOT_CONFIGS)
	$(MAKE) $(U_BOOT_FLAGS) -j$(shell nproc) LOCALVERSION=-$(BUILD_ID)
	grep -aq '$(BUILD_ID)' $(U_BOOT_BIN) || \
		{ echo "ERROR: $(U_BOOT_BIN) lacks $(BUILD_ID)"; exit 1; }

u-boot-clean:
	rm -rf $(U_BOOT_OUTPUT)

################################################################################
# TF-A: BL2 (the TZ image) and the FIP (BL31 + BL32 + BL33)
################################################################################
TF_A_FLAGS ?= PLAT=uno_q SPD=opteed
TF_A_DEBUG ?= 0
TF_A_BUILD  = $(TF_A_PATH)/build/uno_q/$(if $(filter 1,$(TF_A_DEBUG)),debug,release)

.PHONY: tfa tfa-clean

# TF-A does not rebuild when only BUILD_STRING changes; drop the objects that
# embed it so each build carries its own BUILD_ID.
tfa: optee-os u-boot | $(AGATTI_OUT)
	rm -f $(TF_A_BUILD)/bl2/bl_common.o $(TF_A_BUILD)/bl2/bl2_main.o \
	      $(TF_A_BUILD)/bl31/bl_common.o $(TF_A_BUILD)/bl31/bl31_main.o
	CROSS_COMPILE="$(AARCH64_CROSS_COMPILE)" $(MAKE) -C $(TF_A_PATH) \
		-j$(shell nproc) $(TF_A_FLAGS) DEBUG=$(TF_A_DEBUG) \
		BUILD_STRING=$(BUILD_ID) BL32=$(BL32_BIN) BL33=$(U_BOOT_BIN) \
		fip all
	cp $(TF_A_BUILD)/bl2/bl2.elf $(AGATTI_OUT)/bl2.elf
	grep -aq '$(BUILD_ID)' $(AGATTI_OUT)/bl2.elf || \
		{ echo "ERROR: bl2.elf lacks $(BUILD_ID)"; exit 1; }
	$(call record,bl2.elf)

tfa-clean:
	CROSS_COMPILE="$(AARCH64_CROSS_COMPILE)" $(MAKE) -C $(TF_A_PATH) \
		$(TF_A_FLAGS) DEBUG=$(TF_A_DEBUG) clean

################################################################################
# fip.elf: XBL loads the uefi partition image as an ELF with an OEM
# signature, so the FIP is wrapped in an ELF loaded at 0x5f800000 and signed
# with qtestsign by TF-A's generate_fip_elf.sh. The script works in the
# current directory and uses ./qtestsign.
################################################################################
QTESTSIGN_PATH ?= $(ROOT)/qtestsign
FIP_LOAD_ADDR  ?= 0x5f800000
FIP_WORK        = $(AGATTI_OUT)/.fip

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
	mv $(FIP_WORK)/fip.elf $(AGATTI_OUT)/fip.elf
	rm -rf $(FIP_WORK)
	@# BL31, OP-TEE and U-Boot each carry BUILD_ID.
	[ $$(grep -ac '$(BUILD_ID)' $(AGATTI_OUT)/fip.elf) -ge 3 ] || \
		{ echo "ERROR: fip.elf lacks $(BUILD_ID) in BL31, OP-TEE or U-Boot"; exit 1; }
	$(call record,fip.elf)

# A tz.mbn signed from an earlier bl2.elf no longer matches; tz-qti-sign
# makes a new one.
bootimage: fip
	rm -f $(AGATTI_OUT)/tz.mbn
	sed -i '/^tz.mbn /d' $(BUILD_INFO)

################################################################################
# tz-qti-sign: tz.mbn from bl2.elf
#
# sectools signs bl2.elf as a TZ image through the QTI remote signing service
# and validates it. Agatti takes no SWIV segment. sectools, the Agatti TZ
# security profile and a CASS capability come from the Qualcomm signing
# package and account; none of them is needed to build.
################################################################################
SECTOOLS             ?= sectools
QTI_SIGN_DIR         ?=
SECURITY_PROFILE     ?= $(QTI_SIGN_DIR)/agatti_tz_security_profile.xml
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
	@[ -f $(AGATTI_OUT)/bl2.elf ] || \
		{ echo "ERROR: agatti/output/bl2.elf missing: run 'make bootimage' first"; exit 1; }
	$(SECTOOLS) secure-image $(AGATTI_OUT)/bl2.elf \
		--outfile $(AGATTI_OUT)/tz.mbn.tmp \
		--image-id TZ \
		--security-profile $(SECURITY_PROFILE) \
		--qti --sign --signing-mode QTI-REMOTE \
		--cass-capability $(CASS_CAPABILITY) \
		--qti-remote-signing-server-url $(QTI_SIGN_SERVER_URL) \
		--qti-remote-signing-server-port $(QTI_SIGN_SERVER_PORT)
	$(SECTOOLS) secure-image $(AGATTI_OUT)/tz.mbn.tmp --validate --qti \
		--image-id TZ --security-profile $(SECURITY_PROFILE)
	mv $(AGATTI_OUT)/tz.mbn.tmp $(AGATTI_OUT)/tz.mbn
	id=$(call id-of,bl2.elf) && \
		sed -i '/^tz.mbn /d' $(BUILD_INFO) && \
		echo "tz.mbn $$id" >> $(BUILD_INFO)
	$(sha256sums)

################################################################################
# Linux kernel: the Arduino kernel (linux-qcom, as in the UNO Q Yocto image)
# with the patches in agatti/patches/linux/ (the EUD series for this board),
# configured from LINUX_CONFIG: the configuration of the UNO Q Yocto image as
# a defconfig, plus the options below.
#
# linux-patches commits the patches on top of the pinned revision with git am,
# once: it skips them when HEAD is the last patch (same patch ID).
# linux-defconfig applies LINUX_CONFIG and the options below; linux runs it
# when there is no .config.
#
# The configuration builds most drivers as modules. linux-modules installs
# them into LINUX_MODULES_DIR, which the rootfs takes as an overlay, and lists
# LINUX_MODULES_LOAD in /etc/modules for S05modules (agatti/overlay) to load
# at boot: the USB PHY drivers, which the UNO Q needs and the Yocto
# configuration does not build in.
# LINUX_TEST_CONFIGS: MEMTEST, the early memory test that memtest=<N> on the
# kernel command line runs, and the kernel configuration in /proc/config.gz.
# linux fails if any of them is not built in.
################################################################################
LINUX_TEST_CONFIGS  = MEMTEST IKCONFIG IKCONFIG_PROC
LINUX_MODULES_LOAD ?= phy-qcom-qusb2 phy-qcom-qmp-usbc
LINUX_MODULES_DIR   = $(AGATTI_OUT)/modules
LINUX_EXPORTS    = ARCH=arm64 CROSS_COMPILE="$(CCACHE)$(AARCH64_CROSS_COMPILE)"
LINUX_CONFIG    ?= $(CURDIR)/agatti/linux.config
LINUX_PATCHES    = $(sort $(wildcard $(CURDIR)/agatti/patches/linux/*.patch))
LINUX_DT         = qrb2210-arduino-imola
LINUX_DTB        = $(AGATTI_OUT)/$(LINUX_DT).dtb
LINUX_IMAGE      = $(LINUX_PATH)/arch/arm64/boot/Image

.PHONY: linux-patches linux-defconfig linux linux-modules linux-clean

linux-patches:
	@last=$$(git patch-id --stable < $(lastword $(LINUX_PATCHES)) | cut -d' ' -f1); \
	head=$$(git -C $(LINUX_PATH) show HEAD | git patch-id --stable | cut -d' ' -f1); \
	if [ "$$last" = "$$head" ]; then \
		echo "linux: agatti/patches/linux already applied"; \
	else \
		git -C $(LINUX_PATH) -c user.name=agatti.mk -c user.email=agatti.mk@localhost \
			am -q $(LINUX_PATCHES) && \
		echo "linux: applied $(words $(LINUX_PATCHES)) patches from agatti/patches/linux"; \
	fi

linux-defconfig: linux-patches
	$(LINUX_EXPORTS) $(MAKE) -C $(LINUX_PATH) mrproper
	cp $(LINUX_CONFIG) $(LINUX_PATH)/.config
	$(LINUX_EXPORTS) $(MAKE) -C $(LINUX_PATH) olddefconfig
	$(LINUX_EXPORTS) $(LINUX_PATH)/scripts/config --file $(LINUX_PATH)/.config \
		-e TEE \
		-e OPTEE \
		-d QCOMTEE \
		-e DEVTMPFS \
		-e EFI \
		-e EFI_STUB \
		-e VIRTUALIZATION \
		-e KVM \
		-d LOCALVERSION_AUTO \
		$(addprefix -e ,$(LINUX_TEST_CONFIGS))
	$(LINUX_EXPORTS) $(MAKE) -C $(LINUX_PATH) olddefconfig

linux: linux-patches | $(AGATTI_OUT)
	@if [ ! -f $(LINUX_PATH)/.config ]; then \
		$(MAKE) -f $(firstword $(MAKEFILE_LIST)) linux-defconfig; \
	fi
	@for c in $(LINUX_TEST_CONFIGS); do \
		grep -qx "CONFIG_$$c=y" $(LINUX_PATH)/.config || \
		{ echo "ERROR: CONFIG_$$c is not built in: run 'make linux-defconfig'"; exit 1; }; \
	done
	$(LINUX_EXPORTS) $(MAKE) -C $(LINUX_PATH) -j$(shell nproc) \
		LOCALVERSION=-$(BUILD_ID) Image qcom/$(LINUX_DT).dtb
	grep -q -- '-$(BUILD_ID)$$' $(LINUX_PATH)/include/config/kernel.release || \
		{ echo "ERROR: the kernel release lacks $(BUILD_ID)"; exit 1; }
	cp $(LINUX_PATH)/arch/arm64/boot/dts/qcom/$(LINUX_DT).dtb $(LINUX_DTB)

linux-modules: linux
	rm -rf $(LINUX_MODULES_DIR)
	$(LINUX_EXPORTS) $(MAKE) -C $(LINUX_PATH) -j$(shell nproc) \
		LOCALVERSION=-$(BUILD_ID) modules
	$(LINUX_EXPORTS) $(MAKE) -C $(LINUX_PATH) LOCALVERSION=-$(BUILD_ID) \
		INSTALL_MOD_PATH=$(LINUX_MODULES_DIR) INSTALL_MOD_STRIP=1 modules_install
	rm -f $(LINUX_MODULES_DIR)/lib/modules/*/build $(LINUX_MODULES_DIR)/lib/modules/*/source
	@for m in $(LINUX_MODULES_LOAD); do \
		find $(LINUX_MODULES_DIR)/lib/modules -name "$$m.ko*" | grep -q . || \
		{ echo "ERROR: module $$m was not built"; exit 1; }; \
	done
	mkdir -p $(LINUX_MODULES_DIR)/etc
	printf '%s\n' $(LINUX_MODULES_LOAD) > $(LINUX_MODULES_DIR)/etc/modules

buildroot: linux-modules

linux-clean:
	$(LINUX_EXPORTS) $(MAKE) -C $(LINUX_PATH) clean
	rm -rf $(LINUX_DTB) $(LINUX_MODULES_DIR)

################################################################################
# UKI and ESP (efi.bin)
#
# ukify bundles the kernel, the DTB, the Buildroot initramfs and the command
# line into one EFI binary. efi.bin is a FAT32 image holding it both as
# EFI/Linux/uki.efi and as the removable-media fallback EFI/BOOT/bootaa64.efi,
# which U-Boot's bootefi bootmgr starts. 512-byte sectors match the eMMC
# block size and keep the 256 MiB volume FAT32.
#
# Host dependencies: systemd-ukify mtools dosfstools
################################################################################
BR_INITRAMFS  = $(ROOT)/out-br/images/rootfs.cpio.gz
EFI_BIN_SIZE ?= 256M

LINUX_CMDLINE ?= \
	root=/dev/ram0 rw \
	console=ttyMSM0,115200 earlycon \
	clk_ignore_unused pd_ignore_unused \
	qcom_scm.download_mode=1

.PHONY: efi efi-clean

efi: linux buildroot | $(AGATTI_OUT)
	grep -q '$(BUILD_ID)' $(ROOT)/out-br/target/etc/issue || \
		{ echo "ERROR: the rootfs /etc/issue lacks $(BUILD_ID)"; exit 1; }
	rm -f $(AGATTI_OUT)/uki.efi $(AGATTI_OUT)/efi.bin
	ukify build \
		--linux=$(LINUX_IMAGE) \
		--uname=$$(cat $(LINUX_PATH)/include/config/kernel.release) \
		--initrd=$(BR_INITRAMFS) \
		--cmdline='$(LINUX_CMDLINE)' \
		--efi-arch=aa64 \
		--stub=$(CURDIR)/qcom/ukify/linuxaa64.efi.stub \
		--os-release=@/etc/os-release \
		--devicetree=$(LINUX_DTB) \
		--output=$(AGATTI_OUT)/uki.efi
	truncate -s $(EFI_BIN_SIZE) $(AGATTI_OUT)/efi.bin
	mkfs.fat -F 32 -S 512 $(AGATTI_OUT)/efi.bin
	mmd -i $(AGATTI_OUT)/efi.bin ::/EFI ::/EFI/BOOT ::/EFI/Linux
	mcopy -i $(AGATTI_OUT)/efi.bin $(AGATTI_OUT)/uki.efi ::/EFI/Linux/uki.efi
	mcopy -i $(AGATTI_OUT)/efi.bin $(AGATTI_OUT)/uki.efi ::/EFI/BOOT/bootaa64.efi
	$(call record,efi.bin)

efi-clean:
	rm -f $(AGATTI_OUT)/uki.efi $(AGATTI_OUT)/efi.bin

################################################################################
# Flashing over qdl (https://github.com/linux-msm/qdl) with the board in EDL
# mode. The UNO Q boots from eMMC; only the tz, uefi and efi partitions are
# written, so XBL and the rest of the stock firmware stay in place. Both A
# and B slots are written so the boot chain cannot fall back to the stock
# images.
#
# FIREHOSE is the eMMC firehose programmer shipped with the board software.
# tz.mbn comes from agatti/output/ (tz-qti-sign) or, when there is none, from
# agatti/input/. A tz.mbn from tz-qti-sign has to come from the build that
# made fip.elf.
################################################################################
FIREHOSE  ?= $(AGATTI_IN)/prog_firehose_ddr.elf
QDL       ?= qdl
QDL_FLAGS ?= --storage emmc
TZ_MBN     = $(firstword $(wildcard $(AGATTI_OUT)/tz.mbn $(AGATTI_IN)/tz.mbn))

.PHONY: flash-loader flash-kernel

# The inputs of flash-loader and flash-kernel (and flash-lava).
define check-loader
	@[ -f "$(FIREHOSE)" ] || \
		{ echo "ERROR: firehose programmer $(FIREHOSE) missing (see agatti/input/README.md)"; exit 1; }
	@[ -n "$(TZ_MBN)" ] || \
		{ echo "ERROR: no tz.mbn: run 'make tz-qti-sign' or place a signed tz.mbn in agatti/input/"; exit 1; }
	@[ -f $(AGATTI_OUT)/fip.elf ] || \
		{ echo "ERROR: agatti/output/fip.elf missing: run 'make bootimage' first"; exit 1; }
	@[ "$(TZ_MBN)" != "$(AGATTI_OUT)/tz.mbn" ] || \
		{ [ -n "$(call id-of,tz.mbn)" ] && \
		  [ "$(call id-of,tz.mbn)" = "$(call id-of,fip.elf)" ]; } || \
		{ echo "ERROR: tz.mbn and fip.elf are from different builds (see $(BUILD_INFO))"; exit 1; }
endef

define check-kernel
	@[ -f "$(FIREHOSE)" ] || \
		{ echo "ERROR: firehose programmer $(FIREHOSE) missing (see agatti/input/README.md)"; exit 1; }
	@[ -f $(AGATTI_OUT)/efi.bin ] || \
		{ echo "ERROR: agatti/output/efi.bin missing: run 'make efi' first"; exit 1; }
endef

flash-loader:
	$(check-loader)
	$(QDL) $(QDL_FLAGS) $(FIREHOSE) \
		write tz_a $(TZ_MBN) write tz_b $(TZ_MBN) \
		write uefi_a $(AGATTI_OUT)/fip.elf write uefi_b $(AGATTI_OUT)/fip.elf

flash-kernel:
	$(check-kernel)
	$(QDL) $(QDL_FLAGS) $(FIREHOSE) write efi $(AGATTI_OUT)/efi.bin

################################################################################
# flash-lava: flash a board in the LAVA lab (https://lava.infra.foundries.io,
# device type qrb2210-arduino-imola) instead of one on USB
#
# LAVA fetches a flat qcomflash tarball over HTTP and runs qdl next to the
# board (deploy to qdl, boot method qdl, storage emmc). flash-lava writes
# what flash-loader and flash-kernel write: tz_a, tz_b, uefi_a, uefi_b and
# efi. LAVA passes qdl rawprogram files, not partition names, so the tarball
# carries a rawprogram0.xml with the sectors of those partitions in the UNO Q
# eMMC layout (qcom-ptool platforms/qrb2210-unoq/emmc-16GB-arduino, which the
# board's stock image writes) and an empty patch0.xml. qcom/lava/submit.sh
# then uploads the tarball and flashes a board, either interactively
# (qcom/lava/connect.sh reserves a board, flashes it and opens its serial
# console; Ctrl+D releases it) or with a one-shot job that boots it to a login
# prompt (FLASH_LAVA_CONNECT=0, the default without a terminal).
# flash-lava-package only builds the tarball. See qcom/lava/README.md.
################################################################################
FLASH_LAVA_DIR     = $(AGATTI_OUT)/flash-lava
FLASH_LAVA_TARBALL = $(AGATTI_OUT)/agatti-flash.qcomflash.tar.gz
FLASH_LAVA_JOB    ?= $(CURDIR)/agatti/lava/flash-lava.yaml
FLASH_LAVA_SUBMIT  = $(CURDIR)/qcom/lava/submit.sh

# <partition>:<first sector>:<sectors>:<image>, 512-byte sectors
FLASH_LAVA_PARTS = \
	tz_a:145920:8192:tz.mbn tz_b:154112:8192:tz.mbn \
	uefi_a:197120:16384:fip.elf uefi_b:213504:16384:fip.elf \
	efi:1257608:1048576:efi.bin

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
	cp $(AGATTI_OUT)/fip.elf $(AGATTI_OUT)/efi.bin $(FLASH_LAVA_DIR)/
	cd $(FLASH_LAVA_DIR) && { \
		echo '<?xml version="1.0" ?>'; \
		echo '<data>'; \
		for p in $(FLASH_LAVA_PARTS); do \
			set -- $$(echo $$p | tr : ' '); \
			[ $$(stat -c %s $$4) -le $$(($$3 * 512)) ] || \
				{ echo "ERROR: $$4 does not fit in $$1" >&2; exit 1; }; \
			echo "  <program SECTOR_SIZE_IN_BYTES=\"512\" file_sector_offset=\"0\" filename=\"$$4\" label=\"$$1\" num_partition_sectors=\"$$3\" physical_partition_number=\"0\" sparse=\"false\" start_sector=\"$$2\"/>"; \
		done; \
		echo '</data>'; \
	} > rawprogram0.xml
	printf '<?xml version="1.0" ?>\n<patches>\n</patches>\n' > $(FLASH_LAVA_DIR)/patch0.xml
	tar -czf $(FLASH_LAVA_TARBALL) -C $(FLASH_LAVA_DIR) .
	@echo "LAVA flash tarball: $(FLASH_LAVA_TARBALL)"
