################################################################################
# monaco.mk: build system for the Arduino VENTUNO Q (Qualcomm QCS8275, Monaco)
#
# Boot sequence: XBL -> TZ stage -> TF-A BL31 -> OP-TEE -> U-Boot -> Linux
# XBL loads the TZ stage from the tz partition and the uefi partition image
# to DDR at 0xaf000000, then starts the TZ stage at EL3. TZ_IMAGE selects it:
#   bl2         TF-A BL2 (default). The uefi image holds the FIP; BL2 loads
#               BL31, OP-TEE (BL32) and U-Boot (BL33) from it.
#   u-boot-spl  U-Boot SPL. The uefi image holds a FIT with the same three
#               images; SPL loads them and starts BL31.
# U-Boot boots the UKI on the ESP (efi partition) through UEFI.
#
# Outputs, in monaco/output/:
#   bl2.elf     TF-A BL2, the TZ image before signing (TZ_IMAGE=bl2)
#   u-boot-spl.elf
#               U-Boot SPL, the TZ image before signing (TZ_IMAGE=u-boot-spl)
#   tz.mbn      the TZ image with a SWIV segment and a QTI signature
#               (tz-qti-sign), flashed to tz_a and tz_b
#   fip.elf     FIP (BL31 + OP-TEE + U-Boot) wrapped in an ELF loaded at
#               0xaf000000 with a qtestsign test signature, flashed to
#               uefi_a and uefi_b (TZ_IMAGE=bl2)
#   uefi.elf    FIT (BL31 + OP-TEE + U-Boot) wrapped the same way, flashed
#               to uefi_a and uefi_b (TZ_IMAGE=u-boot-spl)
#   efi.bin     FAT32 ESP holding the UKI (kernel, DTB and the Buildroot
#               initramfs), flashed to efi
#
# XBL authenticates the TZ image with the QTI authenticator even when secure
# boot is disabled, so a qtestsign signature is not accepted for tz.mbn,
# whether it holds BL2 or SPL. tz-qti-sign signs the TZ image through the QTI
# remote signing service (CASS); without access to it, place a signed tz.mbn
# in monaco/input/ (see its README.md).
#
# Every invocation stamps BUILD_ID into each component it builds: the TF-A
# build string, the OP-TEE version, the U-Boot and Linux versions and the
# rootfs /etc/issue, so the console shows which build is running.
# monaco/output/build-info.txt records the BUILD_ID of each output.
#
# Main targets
# -----------------------------------------------------------------------------
#   all            bootimage and efi
#   bootimage      the TZ image and the uefi image (OP-TEE, U-Boot, TF-A):
#                  bl2.elf and fip.elf, or u-boot-spl.elf and uefi.elf
#   tz-qti-sign    tz.mbn from the TZ image (QTI remote signing, see above)
#   efi            efi.bin (Linux, Buildroot, UKI)
#   flash-loader   write tz.mbn to tz_a/tz_b and the uefi image to
#                  uefi_a/uefi_b
#   flash-kernel   write efi.bin to efi
#   yocto          the Yocto BSP image (meta-qcom-arduino, ventuno-q)
#   flash-yocto    write the complete Yocto image to the eMMC
#   flash-lava     flash-loader and flash-kernel on a LAVA lab board
#   flash-lava-yocto
#                  flash-yocto on a LAVA lab board
#   efi-kernel-only
#                  efi.bin with this kernel for the Yocto rootfs
#   clean          clean all components and monaco/output/
#
# Component targets: optee-os, u-boot, u-boot-spl, tfa, fip, uefi, linux,
# linux-patches, linux-defconfig, buildroot, buildroot-patches, dsp-firmware,
# qtestsign-fetch, and the matching *-clean targets.
#
# Configurable variables (command line or environment)
# -----------------------------------------------------------------------------
#   BUILD_ID          build identifier (default: monaco-<UTC date-time>)
#   TZ_IMAGE          TZ stage: bl2 (default) or u-boot-spl; pass the same
#                     value to bootimage, tz-qti-sign and flash-loader
#   TF_A_FLAGS        TF-A make flags (default: PLAT=monza SPD=opteed)
#   TF_A_DEBUG        1 for a TF-A debug build (default: 0)
#   U_BOOT_CONFIGS    U-Boot defconfig and config fragments
#   U_BOOT_SPL_CONFIG U-Boot SPL defconfig (default: qcom_monaco_spl_defconfig)
#   LINUX_DEFCONFIG   kernel defconfig (default: defconfig)
#   LINUX_CMDLINE     kernel command line embedded in the UKI
#   FIREHOSE          eMMC firehose programmer used by the flash targets
#                     (default: monaco/input/prog_firehose_ddr.elf)
#   QDL, QDL_FLAGS    qdl binary and its options (default: --storage emmc)
#   FLASH_LAVA_CONNECT
#                     flash-lava*: 1 interactive, 0 flash-only (default: ask
#                     on a terminal, else flash-only)
#   FLASH_LAVA_JOB, FLASH_LAVA_YOCTO_JOB
#                     the LAVA job definitions (default: monaco/lava/*.yaml)
#   tz-qti-sign:      SECTOOLS, QTI_SIGN_DIR, SECURITY_PROFILE,
#                     CASS_CAPABILITY, QTI_SIGN_SERVER_URL,
#                     QTI_SIGN_SERVER_PORT (see the tz-qti-sign section)
################################################################################

################################################################################
# Platform
################################################################################
PLATFORM          = monaco
OPTEE_OS_PLATFORM = qcom-monaco

override COMPILE_NS_USER   := 64
override COMPILE_NS_KERNEL := 64
override COMPILE_S_USER    := 64
override COMPILE_S_KERNEL  := 64

# Evaluated once, so every component of an invocation gets the same value.
ifeq ($(origin BUILD_ID),undefined)
BUILD_ID := $(PLATFORM)-$(shell date -u +%y%m%d-%H%M%S)
endif

MONACO_OUT = $(CURDIR)/monaco/output
MONACO_IN  = $(CURDIR)/monaco/input
BUILD_INFO = $(MONACO_OUT)/build-info.txt

# TZ stage (see the top of this file) and the uefi image that goes with it.
TZ_IMAGE ?= bl2
ifeq ($(TZ_IMAGE),bl2)
UEFI_IMAGE = fip.elf
else ifeq ($(TZ_IMAGE),u-boot-spl)
UEFI_IMAGE = uefi.elf
else
$(error TZ_IMAGE must be bl2 or u-boot-spl)
endif
TZ_ELF = $(TZ_IMAGE).elf

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

# DSP userspace: qrtr (libqrtr, qrtr-ns), tqftpserv and fastrpc (the rpcd
# daemons, fastrpc_test and its libraries), plus stress-ng for qcom-tests.
# Their init scripts come from qcom/overlay and monaco/overlay; the DSP
# firmware and FastRPC runtime from the dsp-firmware target.
BR2_PACKAGE_QRTR_EXT            = y
BR2_PACKAGE_TQFTPSERV_EXT       = y
BR2_PACKAGE_FASTRPC_EXT         = y
BR2_PACKAGE_STRESS_NG           = y
# ALSA tools to route and play audio through the ADSP sound card.
BR2_PACKAGE_ALSA_UTILS          = y
BR2_PACKAGE_ALSA_UTILS_APLAY    = y
BR2_PACKAGE_ALSA_UTILS_AMIXER   = y
# GPU userspace: Mesa freedreno with EGL, OpenGL ES and GBM (Mesa 25.1.8, see
# buildroot-patches), and egl-readback, which renders on the GPU and checks
# the pixels it reads back. The GPU firmware comes from the dsp-firmware
# target.
BR2_PACKAGE_MESA3D                          = y
BR2_PACKAGE_MESA3D_GALLIUM_DRIVER_FREEDRENO = y
BR2_PACKAGE_MESA3D_OPENGL_EGL               = y
BR2_PACKAGE_MESA3D_OPENGL_ES                = y
BR2_PACKAGE_MESA3D_GBM                      = y
BR2_PACKAGE_LIBDRM                          = y
BR2_PACKAGE_EGL_READBACK_EXT                = y
# KVM: kvmtool and the KVM unit tests built for it, with their runner (bash)
# in /opt/kvm-unit-tests, and a small Linux guest (kernel and BusyBox
# initramfs) in /opt/kvm-guest. kvmtool reads console input only from a
# terminal; socat gives it a pty when a script drives the guest console.
BR2_PACKAGE_BUSYBOX_SHOW_OTHERS = y
BR2_PACKAGE_KVMTOOL             = y
BR2_PACKAGE_KVM_UNIT_TESTS_EXT  = y
BR2_PACKAGE_KVM_GUEST_EXT       = y
BR2_PACKAGE_SOCAT               = y
BR2_ROOTFS_OVERLAY              = $(CURDIR)/qcom/overlay $(CURDIR)/monaco/overlay $(DSP_OVERLAY)

################################################################################
# Paths to repositories: the path= attributes in manifest.git/monaco.xml.
# OPTEE_OS_PATH, UBOOT_PATH and LINUX_PATH come from common.mk.
################################################################################
TF_A_PATH ?= $(ROOT)/arm-trusted-firmware

include common.mk
include toolchain.mk

# common.mk passes CFG_IN_TREE_EARLY_TAS to OP-TEE on the make command line,
# which turns the Monaco target.mk's '+= qcom_pas/...' into a no-op. Append
# the qcom_pas PAS TA here (after the include) so it is embedded as an early TA
# and advertised on the TEE bus; qcom_pas_tee (Linux) only binds when that TA
# (cff7d191) is enumerated, and the ADSP, CDSP and GP-DSP0 remoteprocs stay in
# deferred probe without it.
CFG_IN_TREE_EARLY_TAS += qcom_pas/cff7d191-7ca0-4784-af13-48223b9a4fbe

OPTEE_OS_COMMON_EXTRA_FLAGS += TEE_IMPL_VERSION=$(BUILD_ID)

# Buildroot rejects PATH entries containing spaces (Windows paths from WSL).
export PATH := $(shell echo "$$PATH" | tr ':' '\n' | grep -v ' ' | tr '\n' ':' | sed 's/:$$//')

################################################################################
# Top-level targets
################################################################################
.PHONY: all clean bootimage

all: bootimage efi

clean: optee-os-clean u-boot-clean tfa-clean linux-clean buildroot-clean dsp-firmware-clean
	rm -f $(MONACO_OUT)/*.elf $(MONACO_OUT)/*.mbn $(MONACO_OUT)/*.bin \
	      $(MONACO_OUT)/*.efi $(MONACO_OUT)/*.dtb $(MONACO_OUT)/*.itb \
	      $(BUILD_INFO) $(MONACO_OUT)/SHA256SUMS

$(MONACO_OUT):
	mkdir -p $@

# record <output>: note the BUILD_ID the output was built with, replacing the
# line of an earlier build.
define record
	touch $(BUILD_INFO)
	sed -i '/^$(1) /d' $(BUILD_INFO)
	echo "$(1) $(BUILD_ID)" >> $(BUILD_INFO)
	$(sha256sums)
endef

OUTPUT_FILES = bl2.elf u-boot-spl.elf tz.mbn fip.elf uefi.itb uefi.elf efi.bin
sha256sums = cd $(MONACO_OUT) && sha256sum $$(ls $(OUTPUT_FILES) 2>/dev/null) > SHA256SUMS

# id-of <output>: the BUILD_ID build-info.txt records for an output
id-of = $$(sed -n 's/^$(1) //p' $(BUILD_INFO))

.PHONY: help
help:
	@echo "Arduino VENTUNO Q (Qualcomm QCS8275, Monaco) build system"
	@echo ""
	@echo "Boot flow: XBL -> TF-A BL2 or U-Boot SPL (tz.mbn) -> BL31 -> OP-TEE"
	@echo "  -> U-Boot -> Linux (TZ_IMAGE=bl2, the default, or TZ_IMAGE=u-boot-spl)"
	@echo ""
	@echo "Main targets:"
	@echo "  all            bootimage and efi"
	@echo "  bootimage      monaco/output/bl2.elf and fip.elf, or with"
	@echo "                 TZ_IMAGE=u-boot-spl u-boot-spl.elf and uefi.elf"
	@echo "  tz-qti-sign    monaco/output/tz.mbn from the TZ image (QTI remote signing)"
	@echo "  efi            monaco/output/efi.bin (kernel UKI + Buildroot rootfs)"
	@echo "  flash-loader   write tz.mbn and fip.elf or uefi.elf over qdl (board in EDL)"
	@echo "  flash-kernel   write efi.bin over qdl (board in EDL)"
	@echo "  yocto          the Yocto BSP image (meta-qcom-arduino, ventuno-q)"
	@echo "  flash-yocto    write the complete Yocto image over qdl (board in EDL)"
	@echo "  flash-lava     flash-loader and flash-kernel on a LAVA lab board"
	@echo "                 (asks: interactive with the serial console, or flash-only)"
	@echo "  flash-lava-yocto"
	@echo "                 flash-yocto on a LAVA lab board"
	@echo "  efi-kernel-only"
	@echo "                 monaco/output/efi.bin with this kernel for the Yocto rootfs"
	@echo "  clean          clean all components and monaco/output/"
	@echo ""
	@echo "Component targets: optee-os u-boot u-boot-spl tfa fip uefi linux"
	@echo "  linux-patches linux-defconfig buildroot buildroot-patches dsp-firmware"
	@echo "  qtestsign-fetch, and the matching *-clean targets"
	@echo ""
	@echo "Variables: BUILD_ID TZ_IMAGE TF_A_FLAGS TF_A_DEBUG U_BOOT_CONFIGS"
	@echo "  U_BOOT_SPL_CONFIG LINUX_DEFCONFIG LINUX_CMDLINE FIREHOSE QDL QDL_FLAGS"
	@echo "  FLASH_LAVA_CONNECT FLASH_LAVA_JOB FLASH_LAVA_YOCTO_JOB;"
	@echo "  tz-qti-sign: SECTOOLS QTI_SIGN_DIR SECURITY_PROFILE CASS_CAPABILITY"
	@echo "  QTI_SIGN_SERVER_URL QTI_SIGN_SERVER_PORT; yocto: KAS META_QCOM_ARDUINO_REV"

################################################################################
# OP-TEE OS (BL32)
################################################################################
.PHONY: optee-os optee-os-clean

# Raw OP-TEE image, loaded by BL2 from the FIP or by SPL from the FIT.
BL32_BIN = $(OPTEE_OS_PATH)/out/arm/core/tee-raw.bin

optee-os: optee-os-common

optee-os-clean: optee-os-clean-common

################################################################################
# U-Boot (BL33): qcom_defconfig with the TF-A/OP-TEE and board fragments.
# The board fragment sets the monaco-arduino-monza device tree and makes
# U-Boot move the boot to the first Cortex-A55 before it starts anything: the
# Cortex-A78C cores have pointer authentication and the Cortex-A55 cores do
# not, and Linux only brings up CPUs that match its boot CPU.
################################################################################
U_BOOT_CONFIGS ?= qcom_defconfig tfa-optee.config arduino-ventuno-q.config
U_BOOT_OUTPUT   = $(UBOOT_PATH)/.output-monaco
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
# U-Boot SPL (TZ_IMAGE=u-boot-spl): the TZ image. XBL starts it at EL3 at
# TZ_ENTRY in system IMEM, where TF-A BL2 runs otherwise. SPL loads BL31,
# OP-TEE and U-Boot from the FIT XBL has loaded from the uefi partition (see
# uefi) and starts BL31. spl/u-boot-spl.elf is SPL with its device tree,
# wrapped as an ELF for XBL.
################################################################################
U_BOOT_SPL_CONFIG ?= qcom_monaco_spl_defconfig
U_BOOT_SPL_OUTPUT  = $(UBOOT_PATH)/.output-monaco-spl
U_BOOT_SPL_FLAGS   = -C $(UBOOT_PATH) O=$(U_BOOT_SPL_OUTPUT) \
		     CROSS_COMPILE="$(CCACHE)$(AARCH64_CROSS_COMPILE)"
TZ_ENTRY           = 0x14680000

.PHONY: u-boot-spl u-boot-spl-clean

u-boot-spl: | $(MONACO_OUT)
	mkdir -p $(U_BOOT_SPL_OUTPUT)
	$(MAKE) $(U_BOOT_SPL_FLAGS) $(U_BOOT_SPL_CONFIG)
	$(MAKE) $(U_BOOT_SPL_FLAGS) -j$(shell nproc) LOCALVERSION=-$(BUILD_ID) \
		spl/u-boot-spl.elf
	$(AARCH64_CROSS_COMPILE)readelf -h $(U_BOOT_SPL_OUTPUT)/spl/u-boot-spl.elf | \
		grep -q 'Entry point address: *$(TZ_ENTRY)$$' || \
		{ echo "ERROR: u-boot-spl.elf does not start at $(TZ_ENTRY)"; exit 1; }
	cp $(U_BOOT_SPL_OUTPUT)/spl/u-boot-spl.elf $(MONACO_OUT)/u-boot-spl.elf
	grep -aq '$(BUILD_ID)' $(MONACO_OUT)/u-boot-spl.elf || \
		{ echo "ERROR: u-boot-spl.elf lacks $(BUILD_ID)"; exit 1; }
	$(call record,u-boot-spl.elf)

u-boot-spl-clean:
	rm -rf $(U_BOOT_SPL_OUTPUT)

################################################################################
# TF-A: BL2 (the TZ image) and the FIP (BL31 + BL32 + BL33), or with
# TZ_IMAGE=u-boot-spl only BL31, which SPL starts
################################################################################
TF_A_FLAGS ?= PLAT=monza SPD=opteed
TF_A_DEBUG ?= 0
TF_A_BUILD  = $(TF_A_PATH)/build/monza/$(if $(filter 1,$(TF_A_DEBUG)),debug,release)

.PHONY: tfa tfa-clean

# TF-A does not rebuild when only BUILD_STRING changes; drop the objects that
# embed it so each build carries its own BUILD_ID.
ifeq ($(TZ_IMAGE),bl2)
tfa: optee-os u-boot | $(MONACO_OUT)
	rm -f $(TF_A_BUILD)/bl2/bl_common.o $(TF_A_BUILD)/bl2/bl2_main.o \
	      $(TF_A_BUILD)/bl31/bl_common.o $(TF_A_BUILD)/bl31/bl31_main.o
	CROSS_COMPILE="$(AARCH64_CROSS_COMPILE)" $(MAKE) -C $(TF_A_PATH) \
		-j$(shell nproc) $(TF_A_FLAGS) DEBUG=$(TF_A_DEBUG) \
		BUILD_STRING=$(BUILD_ID) BL32=$(BL32_BIN) BL33=$(U_BOOT_BIN) \
		fip all
	cp $(TF_A_BUILD)/bl2/bl2.elf $(MONACO_OUT)/bl2.elf
	grep -aq '$(BUILD_ID)' $(MONACO_OUT)/bl2.elf || \
		{ echo "ERROR: bl2.elf lacks $(BUILD_ID)"; exit 1; }
	$(call record,bl2.elf)
else
tfa: | $(MONACO_OUT)
	rm -f $(TF_A_BUILD)/bl31/bl_common.o $(TF_A_BUILD)/bl31/bl31_main.o
	CROSS_COMPILE="$(AARCH64_CROSS_COMPILE)" $(MAKE) -C $(TF_A_PATH) \
		-j$(shell nproc) $(TF_A_FLAGS) DEBUG=$(TF_A_DEBUG) \
		BUILD_STRING=$(BUILD_ID) bl31
	grep -aq '$(BUILD_ID)' $(TF_A_BUILD)/bl31.bin || \
		{ echo "ERROR: bl31.bin lacks $(BUILD_ID)"; exit 1; }
endif

tfa-clean:
	CROSS_COMPILE="$(AARCH64_CROSS_COMPILE)" $(MAKE) -C $(TF_A_PATH) \
		$(TF_A_FLAGS) DEBUG=$(TF_A_DEBUG) clean

################################################################################
# fip.elf: XBL loads the uefi partition image as an ELF with an OEM
# signature, so the FIP is wrapped in an ELF loaded at 0xaf000000 and signed
# with qtestsign by TF-A's generate_fip_elf.sh. The script works in the
# current directory and uses ./qtestsign.
################################################################################
QTESTSIGN_PATH ?= $(ROOT)/qtestsign
FIP_LOAD_ADDR  ?= 0xaf000000
FIP_WORK        = $(MONACO_OUT)/.fip

.PHONY: qtestsign-fetch fip uefi

qtestsign-fetch:
	@if [ ! -d $(QTESTSIGN_PATH) ]; then \
		echo "Cloning qtestsign..."; \
		git clone https://github.com/msm8916-mainline/qtestsign $(QTESTSIGN_PATH); \
	fi

ifeq ($(TZ_IMAGE),bl2)
fip: tfa qtestsign-fetch
	rm -rf $(FIP_WORK) && mkdir -p $(FIP_WORK)
	ln -s $(QTESTSIGN_PATH) $(FIP_WORK)/qtestsign
	cd $(FIP_WORK) && CROSS_COMPILE="$(AARCH64_CROSS_COMPILE)" \
		$(TF_A_PATH)/tools/qti/generate_fip_elf.sh $(TF_A_BUILD)/fip.bin $(FIP_LOAD_ADDR)
	mv $(FIP_WORK)/fip.elf $(MONACO_OUT)/fip.elf
	rm -rf $(FIP_WORK)
	@# BL31, OP-TEE and U-Boot each carry BUILD_ID.
	[ $$(grep -ac '$(BUILD_ID)' $(MONACO_OUT)/fip.elf) -ge 3 ] || \
		{ echo "ERROR: fip.elf lacks $(BUILD_ID) in BL31, OP-TEE or U-Boot"; exit 1; }
	$(call record,fip.elf)

uefi:
	@echo "ERROR: uefi.elf is the uefi image of TZ_IMAGE=u-boot-spl"; exit 1
else
fip:
	@echo "ERROR: fip.elf is the uefi image of TZ_IMAGE=bl2"; exit 1

################################################################################
# uefi.elf (TZ_IMAGE=u-boot-spl): a FIT with BL31, OP-TEE and U-Boot
# (monaco/uefi.its), wrapped and signed like fip.elf. XBL loads it to
# FIT_LOAD_ADDR, where SPL reads it (CONFIG_SPL_LOAD_FIT_ADDRESS). The images
# are stored after the FIT structure (external data), so SPL only copies the
# structure into its early malloc pool. SPL copies U-Boot to 0xaf400000
# while it still reads the FIT, so the FIT must not reach that address.
################################################################################
FIT_LOAD_ADDR = 0xaf000000
FIT_MAX_SIZE  = 0x400000
UEFI_ITS      = $(CURDIR)/monaco/uefi.its
UEFI_WORK     = $(MONACO_OUT)/.uefi
MKIMAGE       = $(U_BOOT_OUTPUT)/tools/mkimage

uefi: tfa optee-os u-boot u-boot-spl qtestsign-fetch
	grep -qx 'CONFIG_SPL_LOAD_FIT_ADDRESS=$(FIT_LOAD_ADDR)' $(U_BOOT_SPL_OUTPUT)/.config || \
		{ echo "ERROR: SPL does not read the FIT at $(FIT_LOAD_ADDR)"; exit 1; }
	rm -rf $(UEFI_WORK) && mkdir -p $(UEFI_WORK)
	cp $(UEFI_ITS) $(TF_A_BUILD)/bl31.bin $(BL32_BIN) $(U_BOOT_BIN) $(UEFI_WORK)/
	cd $(UEFI_WORK) && $(MKIMAGE) -E -B 0x1000 -f uefi.its $(MONACO_OUT)/uefi.itb
	$(MKIMAGE) -l $(MONACO_OUT)/uefi.itb
	[ $$(stat -c %s $(MONACO_OUT)/uefi.itb) -le $$(($(FIT_MAX_SIZE))) ] || \
		{ echo "ERROR: uefi.itb is larger than $(FIT_MAX_SIZE) bytes"; exit 1; }
	ln -s $(QTESTSIGN_PATH) $(UEFI_WORK)/qtestsign
	cd $(UEFI_WORK) && CROSS_COMPILE="$(AARCH64_CROSS_COMPILE)" \
		$(TF_A_PATH)/tools/qti/generate_fip_elf.sh $(MONACO_OUT)/uefi.itb $(FIT_LOAD_ADDR)
	mv $(UEFI_WORK)/fip.elf $(MONACO_OUT)/uefi.elf
	rm -rf $(UEFI_WORK)
	@# BL31, OP-TEE and U-Boot each carry BUILD_ID.
	[ $$(grep -ac '$(BUILD_ID)' $(MONACO_OUT)/uefi.elf) -ge 3 ] || \
		{ echo "ERROR: uefi.elf lacks $(BUILD_ID) in BL31, OP-TEE or U-Boot"; exit 1; }
	$(call record,uefi.itb)
	$(call record,uefi.elf)
endif

# A tz.mbn signed from an earlier TZ image no longer matches; tz-qti-sign
# makes a new one.
bootimage: $(if $(filter bl2,$(TZ_IMAGE)),fip,u-boot-spl uefi)
	rm -f $(MONACO_OUT)/tz.mbn
	sed -i '/^tz.mbn /d' $(BUILD_INFO)

################################################################################
# tz-qti-sign: tz.mbn from the TZ image (bl2.elf or u-boot-spl.elf)
#
# swiv_build_utility.py adds the SWIV segment, then sectools signs the image
# as a TZ image through the QTI remote signing service and validates it.
# sectools, the Monaco TZ security profile and a CASS capability come from
# the Qualcomm signing package and account; none of them is needed to build.
################################################################################
SWIV_SCRIPT          ?= $(CURDIR)/qcom/security/swiv_build_utility.py
SECTOOLS             ?= sectools
QTI_SIGN_DIR         ?=
SECURITY_PROFILE     ?= $(QTI_SIGN_DIR)/monaco_tz_security_profile.xml
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
	@[ -f $(MONACO_OUT)/$(TZ_ELF) ] || \
		{ echo "ERROR: monaco/output/$(TZ_ELF) missing: run 'make bootimage' first"; exit 1; }
	python3 $(SWIV_SCRIPT) $(MONACO_OUT)/$(TZ_IMAGE)-swiv.elf $(MONACO_OUT)/$(TZ_ELF) monaco
	$(SECTOOLS) secure-image $(MONACO_OUT)/$(TZ_IMAGE)-swiv.elf \
		--outfile $(MONACO_OUT)/tz.mbn.tmp \
		--image-id TZ \
		--security-profile $(SECURITY_PROFILE) \
		--qti --sign --signing-mode QTI-REMOTE \
		--cass-capability $(CASS_CAPABILITY) \
		--qti-remote-signing-server-url $(QTI_SIGN_SERVER_URL) \
		--qti-remote-signing-server-port $(QTI_SIGN_SERVER_PORT)
	$(SECTOOLS) secure-image $(MONACO_OUT)/tz.mbn.tmp --validate --qti \
		--image-id TZ --security-profile $(SECURITY_PROFILE)
	mv $(MONACO_OUT)/tz.mbn.tmp $(MONACO_OUT)/tz.mbn
	rm -f $(MONACO_OUT)/$(TZ_IMAGE)-swiv.elf
	id=$(call id-of,$(TZ_ELF)) && \
		sed -i '/^tz.mbn /d' $(BUILD_INFO) && \
		echo "tz.mbn $$id" >> $(BUILD_INFO)
	$(sha256sums)

################################################################################
# Linux kernel
#
# The pinned kernel with the patches in monaco/patches/linux/ on top: the
# iris video codec series (firmware boot through the OP-TEE PAS with the
# firmware stream mapped by Linux, and the EL2 overlay that enables iris).
# linux-patches commits them with git am, once: it skips them when HEAD is
# the last patch (same patch ID).
#
# linux-defconfig applies LINUX_DEFCONFIG and the options below; linux runs it
# when there is no .config. The kernel has no modules, so everything the
# board needs is built in.
#
# LINUX_DSP_CONFIGS: PAS remoteprocs with the OP-TEE backend, GLINK over
# SMEM, QRTR and FastRPC for the ADSP, CDSP and GPDSP.
# LINUX_TEST_CONFIGS: MEMTEST, the early memory test that memtest=<N> on the
# kernel command line runs (N patterns over all free memory).
# LINUX_VIDEO_CONFIGS: the iris video codec driver (V4L2 mem2mem decoder and
# encoder).
# linux fails if any of them is not built in.
################################################################################
LINUX_DSP_CONFIGS = \
	REMOTEPROC QCOM_Q6V5_PAS QCOM_SYSMON QCOM_PAS QCOM_PAS_TEE QCOM_SCM \
	RPMSG RPMSG_QCOM_GLINK RPMSG_QCOM_GLINK_SMEM QCOM_SMEM QCOM_SMP2P \
	QCOM_SMSM QCOM_IPCC QCOM_AOSS_QMP QCOM_RPMHPD QCOM_COMMAND_DB \
	QRTR QRTR_SMD QCOM_PD_MAPPER QCOM_FASTRPC \
	CMA DMA_CMA DMABUF_HEAPS DMABUF_HEAPS_SYSTEM DMABUF_HEAPS_CMA
LINUX_TEST_CONFIGS = MEMTEST
LINUX_VIDEO_CONFIGS = MEDIA_SUPPORT VIDEO_DEV VIDEO_QCOM_IRIS
LINUX_EXPORTS    = ARCH=arm64 CROSS_COMPILE="$(CCACHE)$(AARCH64_CROSS_COMPILE)"
LINUX_DEFCONFIG ?= defconfig
LINUX_PATCHES    = $(sort $(wildcard $(CURDIR)/monaco/patches/linux/*.patch))
LINUX_DT         = monaco-arduino-monza
# Linux runs at EL2 with no hypervisor underneath: the EL2 overlay hands it
# the resources a hypervisor would own.
LINUX_DT_OVERLAY = monaco-el2
LINUX_DTS_DIR    = $(LINUX_PATH)/arch/arm64/boot/dts/qcom
LINUX_DTB        = $(MONACO_OUT)/$(LINUX_DT)-el2.dtb
LINUX_IMAGE      = $(LINUX_PATH)/arch/arm64/boot/vmlinuz.efi

.PHONY: linux-patches linux-defconfig linux linux-clean

linux-patches:
	@last=$$(git patch-id --stable < $(lastword $(LINUX_PATCHES)) | cut -d' ' -f1); \
	head=$$(git -C $(LINUX_PATH) show HEAD | git patch-id --stable | cut -d' ' -f1); \
	if [ "$$last" = "$$head" ]; then \
		echo "linux: monaco/patches/linux already applied"; \
	else \
		git -C $(LINUX_PATH) -c user.name=monaco.mk -c user.email=monaco.mk@localhost \
			am -q $(LINUX_PATCHES) && \
		echo "linux: applied $(words $(LINUX_PATCHES)) patches from monaco/patches/linux"; \
	fi

linux-defconfig: linux-patches
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
		$(addprefix -e ,$(LINUX_DSP_CONFIGS) $(LINUX_TEST_CONFIGS) $(LINUX_VIDEO_CONFIGS))
	$(LINUX_EXPORTS) $(MAKE) -C $(LINUX_PATH) olddefconfig

# The base DTB is built with symbols (-@) so the EL2 overlay can be applied.
linux: linux-patches | $(MONACO_OUT)
	@if [ ! -f $(LINUX_PATH)/.config ]; then \
		$(MAKE) -f $(firstword $(MAKEFILE_LIST)) linux-defconfig; \
	fi
	@for c in $(LINUX_DSP_CONFIGS) $(LINUX_TEST_CONFIGS) $(LINUX_VIDEO_CONFIGS); do \
		grep -qx "CONFIG_$$c=y" $(LINUX_PATH)/.config || \
		{ echo "ERROR: CONFIG_$$c is not built in: run 'make linux-defconfig'"; exit 1; }; \
	done
	$(LINUX_EXPORTS) $(MAKE) -C $(LINUX_PATH) -j$(shell nproc) \
		LOCALVERSION=-$(BUILD_ID) DTC_FLAGS_$(LINUX_DT)=-@ \
		Image vmlinuz.efi qcom/$(LINUX_DT).dtb qcom/$(LINUX_DT_OVERLAY).dtbo
	grep -q -- '-$(BUILD_ID)$$' $(LINUX_PATH)/include/config/kernel.release || \
		{ echo "ERROR: the kernel release lacks $(BUILD_ID)"; exit 1; }
	$(LINUX_PATH)/scripts/dtc/fdtoverlay -i $(LINUX_DTS_DIR)/$(LINUX_DT).dtb \
		-o $(LINUX_DTB) $(LINUX_DTS_DIR)/$(LINUX_DT_OVERLAY).dtbo
	@# The FastRPC runtime is picked by the DT model (see dsp-firmware).
	$(LINUX_PATH)/scripts/dtc/dtc -q -I dtb -O dts $(LINUX_DTB) | \
		grep -qF 'model = "$(DSP_DT_MODEL)";'

linux-clean:
	$(LINUX_EXPORTS) $(MAKE) -C $(LINUX_PATH) clean
	rm -f $(LINUX_DTB)

################################################################################
# Buildroot patches: monaco/buildroot-patches/*.patch, applied in order to the
# Buildroot tree (common.xml pins 2025.05) before it builds. A patch that
# reverses cleanly is already applied and is skipped.
#   0001  Mesa 25.1.8 from Buildroot 2025.08; Mesa 25.0 does not know the
#         Adreno 623
################################################################################
BR_PATCHES = $(sort $(wildcard $(CURDIR)/monaco/buildroot-patches/*.patch))

.PHONY: buildroot-patches

buildroot: buildroot-patches

buildroot-patches:
	@for p in $(BR_PATCHES); do \
		if git -C $(ROOT)/buildroot apply -R --check $$p 2>/dev/null; then \
			echo "buildroot: $${p##*/} already applied"; \
		else \
			echo "buildroot: applying $${p##*/}"; \
			git -C $(ROOT)/buildroot apply $$p || exit 1; \
		fi; \
	done

################################################################################
# DSP firmware and FastRPC runtime, fetched at pinned revisions into
# monaco/blobs/ and staged into DSP_OVERLAY:
#   /lib/firmware/qcom/qcs8300/  the images the remoteproc firmware-name
#                                properties of the VENTUNO Q DT name (links
#                                resolved to files) and their .jsn
#                                protection-domain lists
#   /usr/share/qcom/             the FastRPC DSP runtime (fastrpc_shell_N,
#                                skels) and the conf.d yaml that maps the DT
#                                model to it
# A DSP only loads a fastrpc_shell or skel whose segment hashes its signed
# image carries, so the runtime has to come from the DSP build of the
# firmware. linux-firmware at DSP_FW_REV has the qcs8300 images at
# DSP_BIN_BUILD. The dsp-binaries Arduino Monza entry links the SA8775P-RIDE
# runtime, which those images reject, so the QCS8300-RIDE runtime of the same
# build is installed under the Arduino Monza path instead;
# qcom/scripts/dsp-runtime-check.py checks the pairing. The same revision
# provides the QUP serial engine firmware (qupv3fw.elf), which Linux loads
# for the engines nothing earlier in the boot has set up, and the Adreno 623
# GPU firmware the msm driver loads from /lib/firmware/qcom (GPU_FW_FILES:
# the GMU firmware and the SQE microcode, under LICENSE.qcom). The EL2 overlay
# disables the zap shader, so its firmware is not installed. VIDEO_FW_FILES is
# the iris firmware (LICENSE.qcom), which iris loads on the first open of a
# video node.
################################################################################
# GitLab serves partial clones; git.kernel.org sends the whole tree.
DSP_FW_REPO   ?= https://gitlab.com/kernel-firmware/linux-firmware.git
DSP_FW_REV    ?= 664f8b6adeba20be0960d9cb1b2ad8c5a4d7e0e3
DSP_FW_FILES   = adsp.mbn adspr.jsn adspua.jsn cdsp0.mbn cdspr.jsn gpdsp0.mbn qupv3fw.elf
GPU_FW_FILES   = qcom/a623_gmu.bin qcom/a650_sqe.fw
VIDEO_FW_FILES = qcom/vpu/vpu30_p4_s6.mbn
# The AudioReach topology the sound card requests (qcom/qcs8300/<model>-tplg.bin)
# is newer than DSP_FW_REV, so it comes from its own pinned revision.
DSP_TPLG_REV  ?= e8a8bc636565a2874b2123684b8ef23f30687c27
DSP_TPLG       = qcom/qcs8300/arduino-monza-tplg.bin
DSP_BIN_REPO  ?= https://github.com/linux-msm/dsp-binaries.git
DSP_BIN_TAG   ?= 20260916
DSP_BIN_BUILD ?= DSP.AT.1.0.1-00170-LEMANS-1
DSP_BIN_SRC    = qcs8300/Qualcomm/QCS8300-RIDE
DSP_BIN_BOARD  = qcs8300/Arduino/Monza
DSP_BIN_CONF   = hexagon-dsp-binaries-arduino-monza.yaml
DSP_DT_MODEL   = Arduino VENTUNO Q
# <firmware>:<runtime directory>, one per remoteproc
DSP_PAIRS      = adsp.mbn:adsp cdsp0.mbn:cdsp gpdsp0.mbn:gdsp0
DSP_OUT        = $(CURDIR)/monaco/blobs
DSP_OVERLAY    = $(DSP_OUT)/overlay
DSP_FW_GIT     = git -C $(DSP_OUT)/linux-firmware
DSP_BIN_GIT    = git -C $(DSP_OUT)/dsp-binaries

.PHONY: dsp-firmware dsp-firmware-clean

buildroot: dsp-firmware

dsp-firmware:
	mkdir -p $(DSP_OUT)
	[ "$$($(DSP_FW_GIT) rev-parse -q --verify HEAD 2>/dev/null)" = $(DSP_FW_REV) ] || { \
		rm -rf $(DSP_OUT)/linux-firmware && \
		git init -q $(DSP_OUT)/linux-firmware && \
		$(DSP_FW_GIT) fetch -q --depth=1 --filter=blob:none $(DSP_FW_REPO) $(DSP_FW_REV) && \
		$(DSP_FW_GIT) sparse-checkout set --no-cone \
			/LICENSE.qcom-2 /qcom/NOTICE.txt /qcom/qcs8300/ /qcom/sa8775p/ && \
		$(DSP_FW_GIT) checkout -q FETCH_HEAD; }
	[ "$$($(DSP_BIN_GIT) describe --tags --exact-match 2>/dev/null)" = $(DSP_BIN_TAG) ] || { \
		rm -rf $(DSP_OUT)/dsp-binaries && \
		git clone -q --depth=1 --filter=blob:none --no-checkout --branch $(DSP_BIN_TAG) \
			$(DSP_BIN_REPO) $(DSP_OUT)/dsp-binaries && \
		$(DSP_BIN_GIT) sparse-checkout set conf.d scripts \
			$(foreach d,adsp cdsp gdsp0,$(DSP_BIN_SRC)/$(d)-$(DSP_BIN_BUILD)) && \
		$(DSP_BIN_GIT) checkout -q; }
	rm -rf $(DSP_OVERLAY)
	mkdir -p $(DSP_OVERLAY)/lib/firmware/qcom/qcs8300 $(DSP_OVERLAY)/lib/firmware/qcom/vpu \
		$(DSP_OVERLAY)/usr/share/qcom/conf.d
	cp $(DSP_OUT)/linux-firmware/LICENSE.qcom-2 $(DSP_OVERLAY)/lib/firmware/
	cp $(DSP_OUT)/linux-firmware/qcom/NOTICE.txt $(DSP_OVERLAY)/lib/firmware/qcom/
	cd $(DSP_OUT)/linux-firmware/qcom/qcs8300 && \
		cp -L $(DSP_FW_FILES) $(DSP_OVERLAY)/lib/firmware/qcom/qcs8300/
	for f in LICENSE.qcom $(GPU_FW_FILES) $(VIDEO_FW_FILES); do \
		$(DSP_FW_GIT) show $(DSP_FW_REV):$$f > $(DSP_OVERLAY)/lib/firmware/$$f || exit 1; \
	done
	$(DSP_FW_GIT) cat-file -e $(DSP_TPLG_REV) 2>/dev/null || \
		$(DSP_FW_GIT) fetch -q --depth=1 --filter=blob:none $(DSP_FW_REPO) $(DSP_TPLG_REV)
	$(DSP_FW_GIT) show $(DSP_TPLG_REV):$(DSP_TPLG) > $(DSP_OVERLAY)/lib/firmware/$(DSP_TPLG)
	$(DSP_FW_GIT) show $(DSP_TPLG_REV):LICENSES/LICENCE.linaro > \
		$(DSP_OVERLAY)/lib/firmware/LICENCE.linaro
	for d in adsp cdsp gdsp0; do \
		printf 'Install: %s\t%s\t%s\n' $(DSP_BIN_SRC) $$d $$d-$(DSP_BIN_BUILD); \
		printf 'Link: %s\t%s\n' $(DSP_BIN_SRC)/dsp/$$d $(DSP_BIN_BOARD)/dsp/$$d; \
	done > $(DSP_OUT)/monaco-config.txt
	cd $(DSP_OUT)/dsp-binaries && \
		./scripts/install.sh $(DSP_OUT)/monaco-config.txt $(DSP_OVERLAY)/usr/share/qcom
	install -m 0644 $(DSP_OUT)/dsp-binaries/conf.d/$(DSP_BIN_CONF) \
		$(DSP_OVERLAY)/usr/share/qcom/conf.d/
	grep -qx '  $(DSP_DT_MODEL):' $(DSP_OVERLAY)/usr/share/qcom/conf.d/$(DSP_BIN_CONF)
	grep -qx '    DSP_LIBRARY_PATH: $(DSP_BIN_BOARD)/dsp' \
		$(DSP_OVERLAY)/usr/share/qcom/conf.d/$(DSP_BIN_CONF)
	python3 $(CURDIR)/qcom/scripts/dsp-runtime-check.py $(DSP_OUT)/dsp-binaries \
		$(foreach p,$(DSP_PAIRS),$(DSP_OVERLAY)/lib/firmware/qcom/qcs8300/$(word 1,$(subst :, ,$(p))):$(DSP_OVERLAY)/usr/share/qcom/$(DSP_BIN_BOARD)/dsp/$(word 2,$(subst :, ,$(p))))

dsp-firmware-clean:
	rm -rf $(DSP_OUT)

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
	qcom_scm.download_mode=1

.PHONY: efi efi-clean

efi: linux buildroot | $(MONACO_OUT)
	grep -q '$(BUILD_ID)' $(ROOT)/out-br/target/etc/issue || \
		{ echo "ERROR: the rootfs /etc/issue lacks $(BUILD_ID)"; exit 1; }
	rm -f $(MONACO_OUT)/uki.efi $(MONACO_OUT)/efi.bin
	ukify build \
		--linux=$(LINUX_IMAGE) \
		--initrd=$(BR_INITRAMFS) \
		--cmdline='$(LINUX_CMDLINE)' \
		--efi-arch=aa64 \
		--stub=$(CURDIR)/qcom/ukify/linuxaa64.efi.stub \
		--os-release=@/etc/os-release \
		--devicetree=$(LINUX_DTB) \
		--output=$(MONACO_OUT)/uki.efi
	truncate -s $(EFI_BIN_SIZE) $(MONACO_OUT)/efi.bin
	mkfs.fat -F 32 -S 512 $(MONACO_OUT)/efi.bin
	mmd -i $(MONACO_OUT)/efi.bin ::/EFI ::/EFI/BOOT ::/EFI/Linux
	mcopy -i $(MONACO_OUT)/efi.bin $(MONACO_OUT)/uki.efi ::/EFI/Linux/uki.efi
	mcopy -i $(MONACO_OUT)/efi.bin $(MONACO_OUT)/uki.efi ::/EFI/BOOT/bootaa64.efi
	$(call record,efi.bin)

efi-clean:
	rm -f $(MONACO_OUT)/uki.efi $(MONACO_OUT)/efi.bin

################################################################################
# Flashing over qdl (https://github.com/linux-msm/qdl) with the board in EDL
# mode. The VENTUNO Q boots from eMMC; only the tz, uefi and efi partitions
# are written, so XBL and the rest of the stock firmware stay in place. Both
# A and B slots are written so the boot chain cannot fall back to the stock
# images.
#
# FIREHOSE is the eMMC firehose programmer shipped with the board software.
# tz.mbn comes from monaco/output/ (tz-qti-sign) or, when there is none, from
# monaco/input/: tz.mbn for BL2, u-boot-spl.mbn for SPL. A tz.mbn from
# tz-qti-sign has to come from the build that made the uefi image.
################################################################################
FIREHOSE  ?= $(MONACO_IN)/prog_firehose_ddr.elf
QDL       ?= qdl
QDL_FLAGS ?= --storage emmc
TZ_INPUT   = $(if $(filter bl2,$(TZ_IMAGE)),tz.mbn,u-boot-spl.mbn)
TZ_MBN     = $(firstword $(wildcard $(MONACO_OUT)/tz.mbn $(MONACO_IN)/$(TZ_INPUT)))

.PHONY: flash-loader flash-kernel

# The inputs of flash-loader and flash-kernel (and flash-lava).
define check-loader
	@[ -f "$(FIREHOSE)" ] || \
		{ echo "ERROR: firehose programmer $(FIREHOSE) missing (see monaco/input/README.md)"; exit 1; }
	@[ -n "$(TZ_MBN)" ] || \
		{ echo "ERROR: no tz.mbn: run 'make tz-qti-sign' or place a signed $(TZ_INPUT) in monaco/input/"; exit 1; }
	@[ -f $(MONACO_OUT)/$(UEFI_IMAGE) ] || \
		{ echo "ERROR: monaco/output/$(UEFI_IMAGE) missing: run 'make bootimage' first"; exit 1; }
	@[ "$(TZ_MBN)" != "$(MONACO_OUT)/tz.mbn" ] || \
		{ [ -n "$(call id-of,tz.mbn)" ] && \
		  [ "$(call id-of,tz.mbn)" = "$(call id-of,$(UEFI_IMAGE))" ]; } || \
		{ echo "ERROR: tz.mbn and $(UEFI_IMAGE) are from different builds (see $(BUILD_INFO))"; exit 1; }
endef

define check-kernel
	@[ -f "$(FIREHOSE)" ] || \
		{ echo "ERROR: firehose programmer $(FIREHOSE) missing (see monaco/input/README.md)"; exit 1; }
	@[ -f $(MONACO_OUT)/efi.bin ] || \
		{ echo "ERROR: monaco/output/efi.bin missing: run 'make efi' first"; exit 1; }
endef

flash-loader:
	$(check-loader)
	$(QDL) $(QDL_FLAGS) $(FIREHOSE) \
		write tz_a $(TZ_MBN) write tz_b $(TZ_MBN) \
		write uefi_a $(MONACO_OUT)/$(UEFI_IMAGE) write uefi_b $(MONACO_OUT)/$(UEFI_IMAGE)

flash-kernel:
	$(check-kernel)
	$(QDL) $(QDL_FLAGS) $(FIREHOSE) write efi $(MONACO_OUT)/efi.bin

################################################################################
# yocto, flash-yocto: the Yocto BSP image for the board, the reference software
#
# yocto builds the ventuno-q machine of meta-qcom-arduino (the Arduino board
# layer on top of meta-qcom) with kas; KAS=kas-container builds in a
# container. flash-yocto writes the complete image (boot firmware, CDT,
# partition table, efi and rootfs) to the eMMC. flash-loader then puts the
# open boot stack in tz and uefi and leaves the Yocto kernel and rootfs in
# place; flash-kernel replaces efi with the UKI.
################################################################################
KAS                   ?= kas
META_QCOM_ARDUINO_URL ?= https://github.com/qualcomm-linux/meta-qcom-arduino
META_QCOM_ARDUINO_REV ?= bd88a3c1575ebfbeecae53bbe52b71bfeb5c652f
META_QCOM_ARDUINO_DIR ?= $(CURDIR)/yocto/meta-qcom-arduino
YOCTO_MACHINE          = ventuno-q
YOCTO_DEPLOY           = $(CURDIR)/yocto/build/tmp/deploy/images/$(YOCTO_MACHINE)
YOCTO_FLASH            = $(YOCTO_DEPLOY)/core-image-base-$(YOCTO_MACHINE).rootfs.qcomflash

.PHONY: yocto flash-yocto yocto-clean

yocto:
	@echo "Building the Yocto BSP image; this takes hours."
	@[ -d $(META_QCOM_ARDUINO_DIR) ] || \
		git clone $(META_QCOM_ARDUINO_URL) $(META_QCOM_ARDUINO_DIR)
	git -C $(META_QCOM_ARDUINO_DIR) checkout -q $(META_QCOM_ARDUINO_REV)
	KAS_WORK_DIR=$(CURDIR)/yocto KAS_BUILD_DIR=$(CURDIR)/yocto/build \
		$(KAS) build $(META_QCOM_ARDUINO_DIR)/ci/$(YOCTO_MACHINE).yml
	@echo "Flash image: $(YOCTO_FLASH)"

flash-yocto:
	@[ -f $(YOCTO_FLASH)/prog_firehose_ddr.elf ] || \
		{ echo "ERROR: $(YOCTO_FLASH) missing: run 'make yocto' first"; exit 1; }
	cd $(YOCTO_FLASH) && \
		$(QDL) $(QDL_FLAGS) prog_firehose_ddr.elf rawprogram*.xml patch*.xml

# efi-kernel-only: an efi.bin that boots this kernel, with the EL2 DTB, on the
# rootfs flash-yocto wrote. It copies the Yocto efi.bin and replaces its UKI;
# flash-kernel writes it.
YOCTO_ROOTFS_CMDLINE ?= root=PARTLABEL=rootfs rw rootwait \
			$(filter-out root=% rw,$(LINUX_CMDLINE))

.PHONY: efi-kernel-only

efi-kernel-only: linux | $(MONACO_OUT)
	@[ -f $(YOCTO_FLASH)/efi.bin ] || \
		{ echo "ERROR: $(YOCTO_FLASH)/efi.bin missing: run 'make yocto' first"; exit 1; }
	rm -f $(MONACO_OUT)/uki.efi $(MONACO_OUT)/efi.bin
	ukify build \
		--linux=$(LINUX_IMAGE) \
		--cmdline='$(YOCTO_ROOTFS_CMDLINE)' \
		--efi-arch=aa64 \
		--stub=$(CURDIR)/qcom/ukify/linuxaa64.efi.stub \
		--os-release=@/etc/os-release \
		--devicetree=$(LINUX_DTB) \
		--output=$(MONACO_OUT)/uki.efi
	cp $(YOCTO_FLASH)/efi.bin $(MONACO_OUT)/efi.bin
	mdeltree -i $(MONACO_OUT)/efi.bin ::/EFI/Linux
	mmd -i $(MONACO_OUT)/efi.bin ::/EFI/Linux
	mcopy -i $(MONACO_OUT)/efi.bin $(MONACO_OUT)/uki.efi ::/EFI/Linux/uki.efi
	$(call record,efi.bin)

yocto-clean:
	rm -rf $(CURDIR)/yocto

################################################################################
# flash-lava, flash-lava-yocto: flash a board in the LAVA lab
# (https://lava.infra.foundries.io, device type monaco-arduino-monza) instead
# of one on USB
#
# LAVA fetches a flat qcomflash tarball over HTTP and runs qdl next to the
# board (deploy to qdl, boot method qdl, storage emmc).
#   flash-lava        writes what flash-loader and flash-kernel write: tz_a,
#                     tz_b, uefi_a, uefi_b and efi. LAVA passes qdl rawprogram
#                     files, not partition names, so the tarball carries a
#                     rawprogram0.xml with the sectors of those partitions in
#                     the VENTUNO Q eMMC layout (qcom-ptool
#                     platforms/qcs8275-monza/emmc, which flash-yocto and the
#                     board's stock image write) and an empty patch0.xml.
#   flash-lava-yocto  writes the complete Yocto image, as flash-yocto does.
# qcom/lava/submit.sh then uploads the tarball and flashes a board, either
# interactively (qcom/lava/connect.sh reserves a board, flashes it and opens
# its serial console; Ctrl+D releases it) or with a one-shot job that boots
# it to a login prompt (FLASH_LAVA_CONNECT=0, the default without a
# terminal). The *-package targets only build the tarballs. See
# qcom/lava/README.md.
################################################################################
FLASH_LAVA_DIR            = $(MONACO_OUT)/flash-lava
FLASH_LAVA_TARBALL        = $(MONACO_OUT)/monaco-flash.qcomflash.tar.gz
FLASH_LAVA_YOCTO_TARBALL  = $(MONACO_OUT)/monaco-yocto.qcomflash.tar.gz
FLASH_LAVA_JOB           ?= $(CURDIR)/monaco/lava/flash-lava.yaml
FLASH_LAVA_YOCTO_JOB     ?= $(CURDIR)/monaco/lava/flash-lava-yocto.yaml
FLASH_LAVA_SUBMIT         = $(CURDIR)/qcom/lava/submit.sh

# <partition>:<first sector>:<sectors>:<image>, 512-byte sectors
FLASH_LAVA_PARTS = \
	tz_a:1153856:8000:tz.mbn tz_b:1918528:8000:tz.mbn \
	uefi_a:158528:10240:$(UEFI_IMAGE) uefi_b:168768:10240:$(UEFI_IMAGE) \
	efi:3207312:1048576:efi.bin

.PHONY: flash-lava flash-lava-package flash-lava-yocto flash-lava-yocto-package

flash-lava: flash-lava-package
	$(FLASH_LAVA_SUBMIT) $(FLASH_LAVA_TARBALL) $(FLASH_LAVA_JOB)

flash-lava-package:
	$(check-loader)
	$(check-kernel)
	rm -rf $(FLASH_LAVA_DIR)
	mkdir -p $(FLASH_LAVA_DIR)
	cp $(FIREHOSE) $(FLASH_LAVA_DIR)/prog_firehose_ddr.elf
	cp $(TZ_MBN) $(FLASH_LAVA_DIR)/tz.mbn
	cp $(MONACO_OUT)/$(UEFI_IMAGE) $(MONACO_OUT)/efi.bin $(FLASH_LAVA_DIR)/
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

flash-lava-yocto: flash-lava-yocto-package
	$(FLASH_LAVA_SUBMIT) $(FLASH_LAVA_YOCTO_TARBALL) $(FLASH_LAVA_YOCTO_JOB)

flash-lava-yocto-package: | $(MONACO_OUT)
	@[ -f $(YOCTO_FLASH)/prog_firehose_ddr.elf ] && [ -f $(YOCTO_FLASH)/rootfs.img ] || \
		{ echo "ERROR: $(YOCTO_FLASH) missing or incomplete: run 'make yocto' first"; exit 1; }
	tar -czf $(FLASH_LAVA_YOCTO_TARBALL) -C $(YOCTO_FLASH) .
	@echo "LAVA flash tarball: $(FLASH_LAVA_YOCTO_TARBALL)"
