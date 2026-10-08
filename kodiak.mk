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
#   tz.mbn      bl2.elf signed with the sectools OEM TEST key (bootimage,
#               tz-oem-sign) or with a QTI signature (tz-qti-sign), flashed
#               to tz_a and tz_b
#   fip.elf     FIP (BL31 + OP-TEE + U-Boot) wrapped in an ELF loaded at
#               0x9fc00000 with a qtestsign test signature, flashed to
#               uefi_a and uefi_b
#   efi.bin     FAT32 ESP holding the UKI (kernel, DTB and the Buildroot
#               initramfs), flashed to efi
#
# The initramfs carries the ADSP and CDSP firmware from linux-firmware, which
# Linux starts through the OP-TEE PAS service, the FastRPC runtime the DSPs
# load their user processes from and the Adreno 643 firmware (dsp-firmware),
# and the GPU userspace (qcom/gpu/gpu.mk). With it the UKI is about 210 MB;
# efi.bin holds it twice.
#
# The XBL of the QCM6490 boot binaries 00142 verifies an OEM-signed BL2, so
# bootimage signs bl2.elf into tz.mbn with the OEM TEST key of Qualcomm's
# public sectools (tz-oem-sign); no Qualcomm account is needed. Older boot
# binaries do not boot that tz.mbn, so the flash targets write the boot
# binaries of that release (bootbinaries-fetch) with the images built here.
# tz-qti-sign signs bl2.elf through the QTI remote signing service (CASS)
# instead; kodiak/input/tz.mbn takes a tz.mbn signed elsewhere.
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
#   bootimage      bl2.elf, tz.mbn (tz-oem-sign) and fip.elf (OP-TEE,
#                  U-Boot, TF-A)
#   tz-oem-sign    tz.mbn from bl2.elf (OEM TEST key, see above)
#   tz-qti-sign    tz.mbn from bl2.elf (QTI remote signing, see above)
#   efi            efi.bin (Linux, Buildroot, UKI)
#   flash-loader   write the boot binaries, tz.mbn to tz_a/tz_b and fip.elf
#                  to uefi_a/uefi_b
#   flash-kernel   write efi.bin to efi
#   flash-lava     flash-loader and flash-kernel on a LAVA lab board
#   clean          clean all components and kodiak/output/
#
# Component targets: optee-os, u-boot, tfa, fip, linux-patches, linux,
# linux-defconfig, buildroot, dsp-firmware, qtestsign-fetch, qtiseclib-fetch,
# sectools-fetch, bootbinaries-fetch, video-streams, and the matching *-clean
# targets.
#
# Configurable variables (command line or environment)
# -----------------------------------------------------------------------------
#   BUILD_ID          build identifier (default: kodiak-<UTC date-time>)
#   TF_A_FLAGS        TF-A make flags (default: PLAT=rb3gen2 SPD=opteed)
#   TF_A_DEBUG        1 for a TF-A debug build (default: 0)
#   QTISECLIB         libqtisec.a (default: kodiak/blobs/libqtisec.a, fetched)
#   DSP_FW_REPO, DSP_FW_REV
#                     linux-firmware repository and revision of the DSP
#                     firmware (see the dsp-firmware section)
#   U_BOOT_CONFIGS    U-Boot defconfig and config fragments
#   U_BOOT_DEVICE_TREE
#                     U-Boot device tree (default: qcom/qcs6490-rb3gen2)
#   LINUX_DEFCONFIG   kernel defconfig (default: defconfig)
#   LINUX_CMDLINE     kernel command line embedded in the UKI
#   FIREHOSE          UFS firehose programmer used by the flash targets
#                     (default: the one in the boot binaries)
#   QDL, QDL_FLAGS    qdl binary and its options (default: --storage ufs)
#   FLASH_LAVA_CONNECT
#                     flash-lava: 1 interactive, 0 flash-only (default: ask
#                     on a terminal, else flash-only)
#   FLASH_LAVA_JOB    the LAVA job definition (default: kodiak/lava/flash-lava.yaml)
#   QCOM_VIDEO_TEST   y to put FFmpeg and the video-codec test streams in
#                     the rootfs (default: y; see qcom/video/video.mk)
#   QCOM_NPU_TEST     y to build the npu-qnn test model into
#                     the rootfs (default: y; needs an x86_64 host, see
#                     qcom/npu/npu.mk)
#   QCOM_GPU          y to put the GPU userspace (Mesa with OpenCL, TensorFlow
#                     Lite with its GPU delegate) in the rootfs (default: y;
#                     see qcom/gpu/gpu.mk)
#   OEM_SECURITY_PROFILE
#                     tz-oem-sign security profile (default:
#                     kodiak/security/kodiak_tzt_security_profile.xml)
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
# DSP userspace: qrtr (libqrtr, qrtr-ns), tqftpserv and fastrpc (the rpcd
# daemons, fastrpc_test and its libraries). Their init scripts come from
# qcom/overlay and kodiak/overlay; the DSP firmware and the FastRPC runtime
# from the dsp-firmware target.
BR2_PACKAGE_QRTR_EXT            = y
BR2_PACKAGE_TQFTPSERV_EXT       = y
BR2_PACKAGE_FASTRPC_EXT         = y
BR2_ROOTFS_OVERLAY              = $(CURDIR)/qcom/overlay $(CURDIR)/kodiak/overlay $(DSP_OVERLAY)

################################################################################
# Paths to repositories: the path= attributes in manifest.git/kodiak.xml.
# OPTEE_OS_PATH, UBOOT_PATH and LINUX_PATH come from common.mk.
################################################################################
TF_A_PATH ?= $(ROOT)/arm-trusted-firmware

include common.mk
include toolchain.mk
include qcom/video/video.mk
include qcom/npu/npu.mk
include qcom/gpu/gpu.mk

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
	@echo "  bootimage      kodiak/output/bl2.elf, tz.mbn (OEM TEST key) and fip.elf"
	@echo "  tz-oem-sign    kodiak/output/tz.mbn from bl2.elf (OEM TEST key)"
	@echo "  tz-qti-sign    kodiak/output/tz.mbn from bl2.elf (QTI remote signing)"
	@echo "  efi            kodiak/output/efi.bin (kernel UKI + Buildroot rootfs)"
	@echo "  flash-loader   write the boot binaries, tz.mbn and fip.elf over qdl"
	@echo "                 (board in EDL)"
	@echo "  flash-kernel   write efi.bin over qdl (board in EDL)"
	@echo "  flash-lava     flash-loader and flash-kernel on a LAVA lab board"
	@echo "                 (asks: interactive with the serial console, or flash-only)"
	@echo "  clean          clean all components and kodiak/output/"
	@echo ""
	@echo "Component targets: optee-os u-boot tfa fip linux-patches linux"
	@echo "  linux-defconfig buildroot dsp-firmware qtestsign-fetch qtiseclib-fetch"
	@echo "  sectools-fetch bootbinaries-fetch video-streams,"
	@echo "  and the matching *-clean targets"
	@echo ""
	@echo "Variables: BUILD_ID TF_A_FLAGS TF_A_DEBUG QTISECLIB DSP_FW_REPO DSP_FW_REV"
	@echo "  U_BOOT_CONFIGS U_BOOT_DEVICE_TREE LINUX_DEFCONFIG LINUX_CMDLINE FIREHOSE"
	@echo "  QDL QDL_FLAGS FLASH_LAVA_CONNECT FLASH_LAVA_JOB QCOM_VIDEO_TEST"
	@echo "  OEM_SECURITY_PROFILE;"
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

# A tz.mbn signed from an earlier bl2.elf no longer matches: bootimage signs
# the new one with the OEM TEST key (tz-qti-sign replaces it with a QTI-signed
# one).
bootimage: fip sectools-fetch
	rm -f $(KODIAK_OUT)/tz.mbn
	sed -i '/^tz.mbn /d' $(BUILD_INFO)
	$(oem-sign)

################################################################################
# tz-oem-sign: tz.mbn from bl2.elf, signed with the OEM TEST key
#
# Qualcomm's sectools, from the public Qualcomm Software Center, signs
# bl2.elf as a TZ-TEE image with its OEM TEST key and the Kodiak security
# profile in kodiak/security/, as ldts/build-kodiak does. The XBL of the boot
# binaries in the boot binaries section accepts the result.
################################################################################
SECTOOLS_VERSION     = 1.50
SECTOOLS_URL         = https://softwarecenter.qualcomm.com/api/download/software/tools/Qualcomm_Security_Tools/All/$(SECTOOLS_VERSION).0/$(SECTOOLS_VERSION).zip
SECTOOLS_SHA256      = 8d6694f1d184e7c204d1e1ea50447a946d7f21838cfddb48b06f0c733d700cbe
SECTOOLS_DIR         = $(ROOT)/toolchains/sectools-$(SECTOOLS_VERSION)
OEM_SECTOOLS         = $(SECTOOLS_DIR)/$(SECTOOLS_VERSION)/Linux/sectools
OEM_SECURITY_PROFILE ?= $(CURDIR)/kodiak/security/kodiak_tzt_security_profile.xml

.PHONY: sectools-fetch sectools-clean tz-oem-sign

sectools-fetch:
	@if [ ! -x $(OEM_SECTOOLS) ]; then \
		mkdir -p $(SECTOOLS_DIR) && \
		curl --retry 5 -fsSL -o $(SECTOOLS_DIR)/sectools.zip $(SECTOOLS_URL) && \
		echo "$(SECTOOLS_SHA256)  $(SECTOOLS_DIR)/sectools.zip" | sha256sum -c && \
		unzip -q -o $(SECTOOLS_DIR)/sectools.zip '$(SECTOOLS_VERSION)/Linux/*' \
			-d $(SECTOOLS_DIR) && \
		chmod +x $(OEM_SECTOOLS) && rm $(SECTOOLS_DIR)/sectools.zip || \
		{ rm -rf $(SECTOOLS_DIR); exit 1; }; \
	fi

sectools-clean:
	rm -rf $(SECTOOLS_DIR)

# oem-sign: sign bl2.elf into tz.mbn, validate it and check that it carries
# the BUILD_ID of bl2.elf.
define oem-sign
	@[ -f $(KODIAK_OUT)/bl2.elf ] || \
		{ echo "ERROR: kodiak/output/bl2.elf missing: run 'make bootimage' first"; exit 1; }
	rm -f $(KODIAK_OUT)/tz.mbn.tmp
	$(OEM_SECTOOLS) secure-image $(KODIAK_OUT)/bl2.elf \
		--outfile $(KODIAK_OUT)/tz.mbn.tmp \
		--image-id TZ-TEE \
		--security-profile $(OEM_SECURITY_PROFILE) \
		--sign --signing-mode TEST
	$(OEM_SECTOOLS) secure-image $(KODIAK_OUT)/tz.mbn.tmp --validate \
		--image-id TZ-TEE --security-profile $(OEM_SECURITY_PROFILE)
	id=$(call id-of,bl2.elf) && \
		grep -aq "$$id" $(KODIAK_OUT)/tz.mbn.tmp && \
		mv $(KODIAK_OUT)/tz.mbn.tmp $(KODIAK_OUT)/tz.mbn && \
		sed -i '/^tz.mbn /d' $(BUILD_INFO) && \
		echo "tz.mbn $$id" >> $(BUILD_INFO)
	$(sha256sums)
endef

tz-oem-sign: sectools-fetch
	$(oem-sign)

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
# The pinned kernel with the patches in kodiak/patches/linux/ on top: the
# fixes that let the DSPs, PAS remote processors with the OP-TEE backend, be
# stopped and started again. linux-patches commits them with git am, once: it skips
# them when HEAD is the last patch (same patch ID).
#
# linux-defconfig applies LINUX_DEFCONFIG and the options below; linux runs it
# when there is no .config. The kernel has no modules, so everything the
# board needs is built in.
#
# LINUX_DSP_CONFIGS: PAS remoteprocs with the OP-TEE backend, GLINK over SMEM,
# QRTR and FastRPC for the ADSP and the CDSP, and the DMA-BUF heaps FastRPC
# clients allocate their buffers from.
# LINUX_TEST_CONFIGS: MEMTEST, the early memory test that memtest=<N> on the
# kernel command line runs (N patterns over all free memory).
# LINUX_VIDEO_CONFIGS: the iris video codec driver (V4L2 mem2mem decoder and
# encoder), which binds the RB3 Gen 2 video core.
# linux fails if any of them is not built in.
# LINUX_OFF_CONFIGS: left out; linux fails if any of them is set.
#   ARM_SMCCC_SOC_ID: the SMCCC SoC ID device (TF-A answers
#   SMCCC_ARCH_SOC_ID) registers before the Qualcomm socinfo device and takes
#   soc0, whose soc_id then reads jep106:0070:<id> instead of the socinfo
#   number. The Qualcomm AI Runtime reads soc0's soc_id as a number and
#   aborts; the socinfo device carries the same SoC ID.
################################################################################
LINUX_DSP_CONFIGS = \
	REMOTEPROC QCOM_Q6V5_PAS QCOM_SYSMON QCOM_PAS QCOM_PAS_TEE QCOM_SCM \
	RPMSG RPMSG_QCOM_GLINK RPMSG_QCOM_GLINK_SMEM QCOM_SMEM QCOM_SMP2P \
	QCOM_IPCC QCOM_AOSS_QMP QCOM_RPMHPD QRTR QRTR_SMD QCOM_PD_MAPPER \
	QCOM_FASTRPC CMA DMA_CMA DMABUF_HEAPS DMABUF_HEAPS_SYSTEM DMABUF_HEAPS_CMA
LINUX_TEST_CONFIGS = MEMTEST
LINUX_OFF_CONFIGS = ARM_SMCCC_SOC_ID
LINUX_VIDEO_CONFIGS = MEDIA_SUPPORT VIDEO_DEV VIDEO_QCOM_IRIS
LINUX_EXPORTS    = ARCH=arm64 CROSS_COMPILE="$(CCACHE)$(AARCH64_CROSS_COMPILE)"
LINUX_DEFCONFIG ?= defconfig
LINUX_PATCHES    = $(sort $(wildcard $(CURDIR)/kodiak/patches/linux/*.patch))
# Linux runs at EL2 with no hypervisor underneath: the Kodiak EL2 overlay,
# applied by the kernel build, hands it the resources a hypervisor would own.
LINUX_DT         = qcs6490-rb3gen2-el2
LINUX_DTB        = $(KODIAK_OUT)/$(LINUX_DT).dtb
LINUX_IMAGE      = $(LINUX_PATH)/arch/arm64/boot/vmlinuz.efi

.PHONY: linux-patches linux-defconfig linux linux-clean

linux-patches:
	@last=$$(git patch-id --stable < $(lastword $(LINUX_PATCHES)) | cut -d' ' -f1); \
	head=$$(git -C $(LINUX_PATH) show HEAD | git patch-id --stable | cut -d' ' -f1); \
	if [ "$$last" = "$$head" ]; then \
		echo "linux: kodiak/patches/linux already applied"; \
	else \
		git -C $(LINUX_PATH) -c user.name=kodiak.mk -c user.email=kodiak.mk@localhost \
			am -q $(LINUX_PATCHES) && \
		echo "linux: applied $(words $(LINUX_PATCHES)) patches from kodiak/patches/linux"; \
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
		$(addprefix -d ,$(LINUX_OFF_CONFIGS)) \
		$(addprefix -e ,$(LINUX_DSP_CONFIGS) $(LINUX_TEST_CONFIGS) $(LINUX_VIDEO_CONFIGS))
	$(LINUX_EXPORTS) $(MAKE) -C $(LINUX_PATH) olddefconfig

linux: linux-patches | $(KODIAK_OUT)
	@if [ ! -f $(LINUX_PATH)/.config ]; then \
		$(MAKE) -f $(firstword $(MAKEFILE_LIST)) linux-defconfig; \
	fi
	@for c in $(LINUX_DSP_CONFIGS) $(LINUX_TEST_CONFIGS) $(LINUX_VIDEO_CONFIGS); do \
		grep -qx "CONFIG_$$c=y" $(LINUX_PATH)/.config || \
		{ echo "ERROR: CONFIG_$$c is not built in: run 'make linux-defconfig'"; exit 1; }; \
	done
	@for c in $(LINUX_OFF_CONFIGS); do \
		! grep -q "^CONFIG_$$c=" $(LINUX_PATH)/.config || \
		{ echo "ERROR: CONFIG_$$c is set: run 'make linux-defconfig'"; exit 1; }; \
	done
	$(LINUX_EXPORTS) $(MAKE) -C $(LINUX_PATH) -j$(shell nproc) \
		LOCALVERSION=-$(BUILD_ID) Image vmlinuz.efi qcom/$(LINUX_DT).dtb
	grep -q -- '-$(BUILD_ID)$$' $(LINUX_PATH)/include/config/kernel.release || \
		{ echo "ERROR: the kernel release lacks $(BUILD_ID)"; exit 1; }
	cp $(LINUX_PATH)/arch/arm64/boot/dts/qcom/$(LINUX_DT).dtb $(LINUX_DTB)
	@# The FastRPC runtime is picked by the DT model (see dsp-firmware).
	$(LINUX_PATH)/scripts/dtc/dtc -q -I dtb -O dts $(LINUX_DTB) | \
		grep -qF 'model = "$(DSP_DT_MODEL)";'

linux-clean:
	$(LINUX_EXPORTS) $(MAKE) -C $(LINUX_PATH) clean
	rm -f $(LINUX_DTB)

################################################################################
# DSP firmware, fetched at a pinned linux-firmware revision into
# kodiak/blobs/dsp/ and staged into DSP_OVERLAY, a rootfs overlay:
#   /lib/firmware/qcom/qcs6490/  the ADSP and CDSP images the remoteproc
#                                firmware-name properties of the RB3 Gen 2 DT
#                                name, and their protection-domain lists
#   /lib/firmware/               LICENSE.qcom and qcom/NOTICE.txt, the terms
#                                they are distributed under
#   /lib/firmware/qcom/vpu/      the video codec firmware (VIDEO_FW_FILES,
#                                VIDEO.VPU.2.0-00055-PROD-1), which iris loads
#                                on the first open of a video node
#   /lib/firmware/qcom/          the Adreno 643 firmware the msm driver loads
#                                when it binds the GPU (GPU_FW_FILES: the SQE
#                                microcode and the GMU firmware); the Kodiak
#                                EL2 overlay disables the zap shader, so its
#                                firmware is not installed
#   /usr/share/qcom/             the FastRPC DSP runtime (fastrpc_shell_N,
#                                skels) and the conf.d yaml that maps the DT
#                                model to it
# linux-firmware ships the files in qcom/qcm6490/ and its WHENCE links them
# into qcom/qcs6490/; DSP_FW_REV has ADSP.HT.5.5.c8-00246-KODIAK-1 and
# CDSP.HT.2.5.c3-00130-KODIAK-1. A DSP only loads a fastrpc_shell or skel
# whose segment hashes its signed image carries, so the runtime is the
# dsp-binaries RB3gen2 runtime of those two builds (DSP_BIN_BUILDS), checked
# against the images by qcom/scripts/dsp-runtime-check.py.
# kodiak/dsp-firmware.sha256 holds the SHA-256 of every staged file, checked
# after staging.
################################################################################
# GitLab serves partial clones; git.kernel.org sends the whole tree.
DSP_FW_REPO  ?= https://gitlab.com/kernel-firmware/linux-firmware.git
DSP_FW_REV   ?= 664f8b6adeba20be0960d9cb1b2ad8c5a4d7e0e3
DSP_FW_SRC    = qcom/qcm6490
DSP_FW_DIR    = qcom/qcs6490
DSP_FW_FILES  = adsp.mbn adspr.jsn adsps.jsn adspua.jsn battmgr.jsn cdsp.mbn cdspr.jsn
VIDEO_FW_FILES = qcom/vpu/vpu20_p1.mbn
GPU_FW_FILES   = qcom/a660_sqe.fw qcom/a660_gmu.bin
DSP_FW_SHA256 = $(CURDIR)/kodiak/dsp-firmware.sha256
DSP_BIN_REPO ?= https://github.com/linux-msm/dsp-binaries.git
DSP_BIN_TAG  ?= 20260916
DSP_BIN_BOARD = qcm6490/Thundercomm/RB3gen2
# <runtime directory>:<build>, one per DSP
DSP_BIN_BUILDS = adsp:ADSP.HT.5.5.c8-00246-KODIAK-1 cdsp:CDSP.HT.2.5.c3-00130-KODIAK-1
DSP_BIN_CONF  = hexagon-dsp-binaries-thundercomm-rb3gen2.yaml
DSP_DT_MODEL  = Qualcomm Technologies, Inc. Robotics RB3gen2
# <firmware>:<runtime directory>, one per remoteproc
DSP_PAIRS     = adsp.mbn:adsp cdsp.mbn:cdsp
DSP_OUT       = $(KODIAK_BLOBS)/dsp
DSP_OVERLAY   = $(DSP_OUT)/overlay
DSP_FW_GIT    = git -C $(DSP_OUT)/linux-firmware
DSP_BIN_GIT   = git -C $(DSP_OUT)/dsp-binaries

.PHONY: dsp-firmware dsp-firmware-clean

buildroot: dsp-firmware

dsp-firmware:
	mkdir -p $(DSP_OUT)
	$(DSP_FW_GIT) cat-file -e $(DSP_FW_REV) 2>/dev/null || { \
		rm -rf $(DSP_OUT)/linux-firmware && \
		git init -q $(DSP_OUT)/linux-firmware && \
		$(DSP_FW_GIT) fetch -q --depth=1 --filter=blob:none $(DSP_FW_REPO) $(DSP_FW_REV); }
	@# Set on every run, so a clone made for an earlier file list gets the new files.
	$(DSP_FW_GIT) sparse-checkout set --no-cone /LICENSE.qcom /qcom/NOTICE.txt \
		$(addprefix /$(DSP_FW_SRC)/,$(DSP_FW_FILES)) $(addprefix /,$(VIDEO_FW_FILES) $(GPU_FW_FILES))
	$(DSP_FW_GIT) checkout -q $(DSP_FW_REV)
	[ "$$($(DSP_BIN_GIT) describe --tags --exact-match 2>/dev/null)" = $(DSP_BIN_TAG) ] || { \
		rm -rf $(DSP_OUT)/dsp-binaries && \
		git clone -q --depth=1 --filter=blob:none --no-checkout --branch $(DSP_BIN_TAG) \
			$(DSP_BIN_REPO) $(DSP_OUT)/dsp-binaries && \
		$(DSP_BIN_GIT) sparse-checkout set conf.d scripts \
			$(foreach b,$(DSP_BIN_BUILDS),$(DSP_BIN_BOARD)/$(lastword $(subst :, ,$(b)))) && \
		$(DSP_BIN_GIT) checkout -q; }
	rm -rf $(DSP_OVERLAY)
	mkdir -p $(DSP_OVERLAY)/lib/firmware/$(DSP_FW_DIR) $(DSP_OVERLAY)/lib/firmware/qcom/vpu \
		$(DSP_OVERLAY)/usr/share/qcom/conf.d
	cp $(DSP_OUT)/linux-firmware/LICENSE.qcom $(DSP_OVERLAY)/lib/firmware/
	cp $(DSP_OUT)/linux-firmware/qcom/NOTICE.txt $(DSP_OVERLAY)/lib/firmware/qcom/
	cd $(DSP_OUT)/linux-firmware/$(DSP_FW_SRC) && \
		cp $(DSP_FW_FILES) $(DSP_OVERLAY)/lib/firmware/$(DSP_FW_DIR)/
	for f in $(VIDEO_FW_FILES) $(GPU_FW_FILES); do \
		cp $(DSP_OUT)/linux-firmware/$$f $(DSP_OVERLAY)/lib/firmware/$$f || exit 1; \
	done
	for b in $(DSP_BIN_BUILDS); do \
		printf 'Install: %s\t%s\t%s\n' $(DSP_BIN_BOARD) $${b%%:*} $${b#*:}; \
	done > $(DSP_OUT)/kodiak-config.txt
	cd $(DSP_OUT)/dsp-binaries && \
		./scripts/install.sh $(DSP_OUT)/kodiak-config.txt $(DSP_OVERLAY)/usr/share/qcom
	install -m 0644 $(DSP_OUT)/dsp-binaries/conf.d/$(DSP_BIN_CONF) \
		$(DSP_OVERLAY)/usr/share/qcom/conf.d/
	grep -qx '  $(DSP_DT_MODEL):' $(DSP_OVERLAY)/usr/share/qcom/conf.d/$(DSP_BIN_CONF)
	grep -qx '    DSP_LIBRARY_PATH: $(DSP_BIN_BOARD)/dsp' \
		$(DSP_OVERLAY)/usr/share/qcom/conf.d/$(DSP_BIN_CONF)
	python3 $(CURDIR)/qcom/scripts/dsp-runtime-check.py $(DSP_OUT)/dsp-binaries \
		$(foreach p,$(DSP_PAIRS),$(DSP_OVERLAY)/lib/firmware/$(DSP_FW_DIR)/$(word 1,$(subst :, ,$(p))):$(DSP_OVERLAY)/usr/share/qcom/$(DSP_BIN_BOARD)/dsp/$(word 2,$(subst :, ,$(p))))
	cd $(DSP_OVERLAY) && sha256sum --quiet -c $(DSP_FW_SHA256)
	@[ $$(cd $(DSP_OVERLAY) && find . -type f | wc -l) -eq $$(wc -l < $(DSP_FW_SHA256)) ] || \
		{ echo "ERROR: $(DSP_OVERLAY) and $(DSP_FW_SHA256) list different files"; exit 1; }

dsp-firmware-clean:
	rm -rf $(DSP_OUT)

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
# Boot binaries: XBL, XBL config, AOP and the rest of the QCM6490 boot
# firmware of the public test-device release, with its UFS firehose
# programmer. Release 00142 is the first whose XBL (xbl_sec) verifies an
# OEM-signed BL2. cpucp.elf is not in the main archive: it ships in the
# immutable companion archive of the same release, which meta-qcom's
# firmware-qcom-boot-qcs6490 recipe deploys with it. bootbinaries-fetch
# downloads both once, checks their hashes and unpacks them into
# kodiak/blobs/bootbinaries/.
################################################################################
BOOTBIN_VERSION = 00142
BOOTBIN_BASE    = https://softwarecenter.qualcomm.com/nexus/generic/product/chip/tech-package/QCM6490_bootbinaries.1.0/qcm6490_bootbinaries.1.0-test-device-public/$(BOOTBIN_VERSION)
BOOTBIN_ZIP     = QCM6490_bootbinaries_$(BOOTBIN_VERSION).zip
BOOTBIN_SHA256  = 22e45047b3349a1611d27167616dd04f08e8351120ac121f6921b47b9f709216
BOOTBIN_IMM_ZIP    = QCM6490_bootbinaries_immutable_$(BOOTBIN_VERSION).zip
BOOTBIN_IMM_SHA256 = a5f48c1646eb640377b66fa13064f2efe6f667e60f714b0e06c34dc66b7c94fb
BOOTBIN_DIR     = $(KODIAK_BLOBS)/bootbinaries
BOOTBIN_STAMP   = $(BOOTBIN_DIR)/.fetched-$(BOOTBIN_VERSION)

# fetch-zip <zip> <sha256>: download a boot binaries archive into
# kodiak/blobs/, check its hash and unpack it flat into BOOTBIN_DIR.
define fetch-zip
	[ -f $(KODIAK_BLOBS)/$(1) ] || \
		curl --retry 5 -fsSL -o $(KODIAK_BLOBS)/$(1) $(BOOTBIN_BASE)/$(1) || \
		{ rm -f $(KODIAK_BLOBS)/$(1); exit 1; }
	echo "$(2)  $(KODIAK_BLOBS)/$(1)" | sha256sum -c
	unzip -q -j -o $(KODIAK_BLOBS)/$(1) -d $(BOOTBIN_DIR)
endef

.PHONY: bootbinaries-fetch

bootbinaries-fetch: $(BOOTBIN_STAMP)

$(BOOTBIN_STAMP):
	rm -rf $(BOOTBIN_DIR)
	mkdir -p $(BOOTBIN_DIR)
	$(call fetch-zip,$(BOOTBIN_ZIP),$(BOOTBIN_SHA256))
	$(call fetch-zip,$(BOOTBIN_IMM_ZIP),$(BOOTBIN_IMM_SHA256))
	touch $@

################################################################################
# Flashing over qdl (https://github.com/linux-msm/qdl) with the board in EDL
# mode. The RB3 Gen 2 boots from UFS. flash-loader writes the boot binaries
# above (XBL and XBL config on LUN 1 and LUN 2, the rest on LUN 4), tz.mbn and
# fip.elf; flash-kernel writes the efi partition (LUN 0). The partition tables
# and the other partitions stay as they are. Both A and B slots are written
# so the boot chain cannot fall back to older images.
#
# FIREHOSE is the UFS firehose programmer of the boot binaries. tz.mbn comes
# from kodiak/output/ (bootimage, tz-oem-sign or tz-qti-sign) or, when there
# is none, from kodiak/input/. A tz.mbn from kodiak/output/ has to come from
# the build that made fip.elf.
#
# The flash targets stage what they write in a directory with a qdl
# rawprogram<LUN>.xml for each LUN, at the place of each partition in the
# RB3 Gen 2 UFS layout (qcom-ptool platforms/qcs6490-rb3gen2/ufs, which the
# board's stock image writes), and empty patch files.
################################################################################
FIREHOSE  ?= $(BOOTBIN_DIR)/prog_firehose_ddr.elf
QDL       ?= qdl
QDL_FLAGS ?= --storage ufs
TZ_MBN     = $(firstword $(wildcard $(KODIAK_OUT)/tz.mbn $(KODIAK_IN)/tz.mbn))

# <LUN>:<partition>:<first sector>:<sectors>:<image>, 4096-byte sectors
FLASH_BOOT_PARTS = \
	1:xbl_a:6:901:xbl.elf 1:xbl_config_a:907:128:xbl_config.elf \
	1:xbl_b:1035:901:xbl.elf 1:xbl_config_b:1936:128:xbl_config.elf \
	2:xbl_a:6:901:xbl.elf 2:xbl_config_a:907:128:xbl_config.elf \
	2:xbl_b:1035:901:xbl.elf 2:xbl_config_b:1936:128:xbl_config.elf \
	4:aop_a:6:128:aop.mbn 4:xbl_ramdump_a:16582:512:XblRamdump.elf \
	4:hyp_a:19398:2048:hypvm.mbn 4:devcfg_a:21446:32:devcfg.mbn \
	4:qupfw_a:21478:20:qupv3fw.elf 4:uefisecapp_a:21498:512:uefi_sec.mbn \
	4:imagefv_a:22010:512:imagefv.elf 4:shrm_a:22522:32:shrm.elf \
	4:multiimgoem_a:22554:8:multi_image.mbn 4:cpucp_a:22562:256:cpucp.elf \
	4:aop_b:22882:128:aop.mbn 4:xbl_ramdump_b:39458:512:XblRamdump.elf \
	4:hyp_b:42274:2048:hypvm.mbn 4:devcfg_b:44322:32:devcfg.mbn \
	4:qupfw_b:44354:20:qupv3fw.elf 4:uefisecapp_b:44374:512:uefi_sec.mbn \
	4:imagefv_b:44886:512:imagefv.elf 4:shrm_b:45398:32:shrm.elf \
	4:multiimgoem_b:45430:8:multi_image.mbn 4:cpucp_b:45438:256:cpucp.elf \
	4:toolsfv:66151:256:tools.fv
FLASH_LOADER_PARTS = $(FLASH_BOOT_PARTS) \
	4:uefi_a:17094:1280:fip.elf 4:tz_a:18374:1024:tz.mbn \
	4:uefi_b:39970:1280:fip.elf 4:tz_b:41250:1024:tz.mbn
FLASH_KERNEL_PARTS = 0:efi:6:131072:efi.bin
FLASH_LOADER_DIR   = $(KODIAK_OUT)/flash-loader

# flash-dir <directory> <parts>: stage the firehose programmer, the images of
# <parts> and a rawprogram<LUN>.xml and an empty patch<LUN>.xml per LUN.
define flash-dir
	rm -rf $(1)
	mkdir -p $(1)
	cp $(FIREHOSE) $(1)/prog_firehose_ddr.elf
	cd $(1) && for p in $(2); do \
		f=$${p##*:}; \
		case $$f in \
		tz.mbn) src=$(TZ_MBN) ;; \
		fip.elf|efi.bin) src=$(KODIAK_OUT)/$$f ;; \
		*) src=$(BOOTBIN_DIR)/$$f ;; \
		esac; \
		[ -f $$f ] || cp $$src $$f || exit 1; \
	done
	cd $(1) && for lun in $$(for p in $(2); do echo $${p%%:*}; done | sort -u); do { \
		echo '<?xml version="1.0" ?>'; \
		echo '<data>'; \
		for p in $(2); do \
			set -- $$(echo $$p | tr : ' '); \
			[ $$1 = $$lun ] || continue; \
			[ $$(stat -c %s $$5) -le $$(($$4 * 4096)) ] || \
				{ echo "ERROR: $$5 does not fit in $$2" >&2; exit 1; }; \
			echo "  <program SECTOR_SIZE_IN_BYTES=\"4096\" file_sector_offset=\"0\" filename=\"$$5\" label=\"$$2\" num_partition_sectors=\"$$4\" physical_partition_number=\"$$1\" sparse=\"false\" start_sector=\"$$3\"/>"; \
		done; \
		echo '</data>'; \
	} > rawprogram$$lun.xml || exit 1; \
	printf '<?xml version="1.0" ?>\n<patches>\n</patches>\n' > patch$$lun.xml; done
endef

.PHONY: flash-loader flash-kernel

# The inputs of flash-loader and flash-kernel (and flash-lava).
define check-loader
	@[ -f "$(FIREHOSE)" ] || \
		{ echo "ERROR: firehose programmer $(FIREHOSE) missing: run 'make bootbinaries-fetch' or set FIREHOSE"; exit 1; }
	@[ -n "$(TZ_MBN)" ] || \
		{ echo "ERROR: no tz.mbn: run 'make bootimage' or place a signed tz.mbn in kodiak/input/"; exit 1; }
	@[ -f $(KODIAK_OUT)/fip.elf ] || \
		{ echo "ERROR: kodiak/output/fip.elf missing: run 'make bootimage' first"; exit 1; }
	@[ "$(TZ_MBN)" != "$(KODIAK_OUT)/tz.mbn" ] || \
		{ [ -n "$(call id-of,tz.mbn)" ] && \
		  [ "$(call id-of,tz.mbn)" = "$(call id-of,fip.elf)" ]; } || \
		{ echo "ERROR: tz.mbn and fip.elf are from different builds (see $(BUILD_INFO))"; exit 1; }
endef

define check-kernel
	@[ -f "$(FIREHOSE)" ] || \
		{ echo "ERROR: firehose programmer $(FIREHOSE) missing: run 'make bootbinaries-fetch' or set FIREHOSE"; exit 1; }
	@[ -f $(KODIAK_OUT)/efi.bin ] || \
		{ echo "ERROR: kodiak/output/efi.bin missing: run 'make efi' first"; exit 1; }
endef

flash-loader: bootbinaries-fetch
	$(check-loader)
	$(call flash-dir,$(FLASH_LOADER_DIR),$(FLASH_LOADER_PARTS))
	cd $(FLASH_LOADER_DIR) && $(QDL) $(QDL_FLAGS) prog_firehose_ddr.elf \
		rawprogram1.xml rawprogram2.xml rawprogram4.xml \
		patch1.xml patch2.xml patch4.xml

flash-kernel: bootbinaries-fetch
	$(check-kernel)
	$(QDL) $(QDL_FLAGS) $(FIREHOSE) write efi $(KODIAK_OUT)/efi.bin

################################################################################
# flash-lava: flash a board in the LAVA lab (https://lava.infra.foundries.io,
# device type qcs6490-rb3gen2) instead of one on USB
#
# LAVA fetches a flat qcomflash tarball over HTTP and runs qdl next to the
# board (deploy to qdl, boot method qdl, storage ufs). flash-lava writes what
# flash-loader and flash-kernel write: the tarball carries their images, the
# firehose programmer, rawprogram0.xml, rawprogram1.xml, rawprogram2.xml and
# rawprogram4.xml and empty patch files. qcom/lava/submit.sh then uploads the tarball and flashes
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

.PHONY: flash-lava flash-lava-package

flash-lava: flash-lava-package
	$(FLASH_LAVA_SUBMIT) $(FLASH_LAVA_TARBALL) $(FLASH_LAVA_JOB)

flash-lava-package: bootbinaries-fetch
	$(check-loader)
	$(check-kernel)
	$(call flash-dir,$(FLASH_LAVA_DIR),$(FLASH_LOADER_PARTS) $(FLASH_KERNEL_PARTS))
	tar -czf $(FLASH_LAVA_TARBALL) -C $(FLASH_LAVA_DIR) .
	@echo "LAVA flash tarball: $(FLASH_LAVA_TARBALL)"
