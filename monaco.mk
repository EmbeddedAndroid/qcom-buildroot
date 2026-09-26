################################################################################
# monaco.mk: build system for the Arduino VENTUNO Q (Qualcomm QCS8275, Monaco)
#
# Boot sequence: XBL -> TF-A BL2 -> TF-A BL31 -> OP-TEE -> U-Boot -> Linux
# XBL loads TF-A BL2 from the tz partition and the FIP from the uefi
# partition; BL2 loads BL31, OP-TEE (BL32) and U-Boot (BL33) from the FIP.
# U-Boot boots the UKI on the ESP (efi partition) through UEFI.
#
# Outputs, in monaco/output/:
#   bl2.elf     TF-A BL2, the TZ image before signing
#   tz.mbn      bl2.elf with a SWIV segment and a QTI signature (tz-qti-sign),
#               flashed to tz_a and tz_b
#   fip.elf     FIP (BL31 + OP-TEE + U-Boot) wrapped in an ELF loaded at
#               0xaf000000 with a qtestsign test signature, flashed to
#               uefi_a and uefi_b
#   efi.bin     FAT32 ESP holding the UKI (kernel, DTB and the Buildroot
#               initramfs), flashed to efi
#
# XBL authenticates the TZ image with the QTI authenticator even when secure
# boot is disabled, so a qtestsign signature is not accepted for tz.mbn.
# tz-qti-sign signs bl2.elf through the QTI remote signing service (CASS); without
# access to it, place a signed tz.mbn in monaco/input/ (see its README.md).
#
# Every invocation stamps BUILD_ID into each component it builds: the TF-A
# build string, the OP-TEE version, the U-Boot and Linux versions and the
# rootfs /etc/issue, so the console shows which build is running.
# monaco/output/build-info.txt records the BUILD_ID of each output.
#
# Main targets
# -----------------------------------------------------------------------------
#   all            bootimage and efi
#   bootimage      bl2.elf and fip.elf (OP-TEE, U-Boot, TF-A)
#   tz-qti-sign    tz.mbn from bl2.elf (QTI remote signing, see above)
#   efi            efi.bin (Linux, Buildroot, UKI)
#   flash-loader   write tz.mbn to tz_a/tz_b and fip.elf to uefi_a/uefi_b
#   flash-kernel   write efi.bin to efi
#   clean          clean all components and monaco/output/
#
# Component targets: optee-os, u-boot, tfa, fip, linux, linux-defconfig,
# buildroot, dsp-firmware, qtestsign-fetch, and the matching *-clean targets.
#
# Configurable variables (command line or environment)
# -----------------------------------------------------------------------------
#   BUILD_ID          build identifier (default: monaco-<UTC date-time>)
#   TF_A_FLAGS        TF-A make flags (default: PLAT=monza SPD=opteed)
#   TF_A_DEBUG        1 for a TF-A debug build (default: 0)
#   U_BOOT_CONFIGS    U-Boot defconfig and config fragments
#   LINUX_DEFCONFIG   kernel defconfig (default: defconfig)
#   LINUX_CMDLINE     kernel command line embedded in the UKI
#   FIREHOSE          eMMC firehose programmer used by the flash targets
#                     (default: monaco/input/prog_firehose_ddr.elf)
#   QDL, QDL_FLAGS    qdl binary and its options (default: --storage emmc)
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
	      $(MONACO_OUT)/*.efi $(MONACO_OUT)/*.dtb $(BUILD_INFO) \
	      $(MONACO_OUT)/SHA256SUMS

$(MONACO_OUT):
	mkdir -p $@

# record <output>: note the BUILD_ID the output was built with, replacing the
# line of an earlier build.
define record
	touch $(BUILD_INFO)
	sed -i '/^$(1) /d' $(BUILD_INFO)
	echo "$(1) $(BUILD_ID)" >> $(BUILD_INFO)
	cd $(MONACO_OUT) && sha256sum $$(ls bl2.elf tz.mbn fip.elf efi.bin 2>/dev/null) > SHA256SUMS
endef

.PHONY: help
help:
	@echo "Arduino VENTUNO Q (Qualcomm QCS8275, Monaco) build system"
	@echo ""
	@echo "Boot flow: XBL -> TF-A BL2 (tz.mbn) -> BL31 -> OP-TEE -> U-Boot -> Linux"
	@echo ""
	@echo "Main targets:"
	@echo "  all            bootimage and efi"
	@echo "  bootimage      monaco/output/bl2.elf and fip.elf (uefi partitions)"
	@echo "  tz-qti-sign    monaco/output/tz.mbn from bl2.elf (QTI remote signing)"
	@echo "  efi            monaco/output/efi.bin (kernel UKI + Buildroot rootfs)"
	@echo "  flash-loader   write tz.mbn and fip.elf over qdl (board in EDL)"
	@echo "  flash-kernel   write efi.bin over qdl (board in EDL)"
	@echo "  clean          clean all components and monaco/output/"
	@echo ""
	@echo "Component targets: optee-os u-boot tfa fip linux linux-defconfig"
	@echo "  buildroot dsp-firmware qtestsign-fetch, and the matching *-clean targets"
	@echo ""
	@echo "Variables: BUILD_ID TF_A_FLAGS TF_A_DEBUG U_BOOT_CONFIGS LINUX_DEFCONFIG"
	@echo "  LINUX_CMDLINE FIREHOSE QDL QDL_FLAGS; tz-qti-sign: SECTOOLS QTI_SIGN_DIR"
	@echo "  SECURITY_PROFILE CASS_CAPABILITY QTI_SIGN_SERVER_URL QTI_SIGN_SERVER_PORT"

################################################################################
# OP-TEE OS (BL32)
################################################################################
.PHONY: optee-os optee-os-clean

# Raw OP-TEE image, loaded by BL2 from the FIP.
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
# TF-A: BL2 (the TZ image) and the FIP (BL31 + BL32 + BL33)
################################################################################
TF_A_FLAGS ?= PLAT=monza SPD=opteed
TF_A_DEBUG ?= 0
TF_A_BUILD  = $(TF_A_PATH)/build/monza/$(if $(filter 1,$(TF_A_DEBUG)),debug,release)

.PHONY: tfa tfa-clean

# TF-A does not rebuild when only BUILD_STRING changes; drop the objects that
# embed it so each build carries its own BUILD_ID.
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
	mv $(FIP_WORK)/fip.elf $(MONACO_OUT)/fip.elf
	rm -rf $(FIP_WORK)
	@# BL31, OP-TEE and U-Boot each carry BUILD_ID.
	[ $$(grep -ac '$(BUILD_ID)' $(MONACO_OUT)/fip.elf) -ge 3 ] || \
		{ echo "ERROR: fip.elf lacks $(BUILD_ID) in BL31, OP-TEE or U-Boot"; exit 1; }
	$(call record,fip.elf)

# A tz.mbn signed from an earlier bl2.elf no longer matches; tz-qti-sign makes a
# new one.
bootimage: fip
	rm -f $(MONACO_OUT)/tz.mbn
	sed -i '/^tz.mbn /d' $(BUILD_INFO)

################################################################################
# tz-qti-sign: tz.mbn from bl2.elf
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
	@[ -f $(MONACO_OUT)/bl2.elf ] || \
		{ echo "ERROR: monaco/output/bl2.elf missing: run 'make bootimage' first"; exit 1; }
	python3 $(SWIV_SCRIPT) $(MONACO_OUT)/bl2-swiv.elf $(MONACO_OUT)/bl2.elf monaco
	$(SECTOOLS) secure-image $(MONACO_OUT)/bl2-swiv.elf \
		--outfile $(MONACO_OUT)/tz.mbn \
		--image-id TZ \
		--security-profile $(SECURITY_PROFILE) \
		--qti --sign --signing-mode QTI-REMOTE \
		--cass-capability $(CASS_CAPABILITY) \
		--qti-remote-signing-server-url $(QTI_SIGN_SERVER_URL) \
		--qti-remote-signing-server-port $(QTI_SIGN_SERVER_PORT)
	$(SECTOOLS) secure-image $(MONACO_OUT)/tz.mbn --validate --qti \
		--image-id TZ --security-profile $(SECURITY_PROFILE)
	rm -f $(MONACO_OUT)/bl2-swiv.elf
	id=$$(sed -n 's/^bl2.elf //p' $(BUILD_INFO)) && \
		sed -i '/^tz.mbn /d' $(BUILD_INFO) && \
		echo "tz.mbn $$id" >> $(BUILD_INFO)
	cd $(MONACO_OUT) && sha256sum $$(ls bl2.elf tz.mbn fip.elf efi.bin 2>/dev/null) > SHA256SUMS

################################################################################
# Linux kernel
#
# linux-defconfig applies LINUX_DEFCONFIG and the options below; linux runs it
# when there is no .config. The kernel has no modules, so everything the
# board needs is built in.
#
# LINUX_DSP_CONFIGS: PAS remoteprocs with the OP-TEE backend, GLINK over
# SMEM, QRTR and FastRPC for the ADSP, CDSP and GPDSP. linux fails if any of
# them is not built in.
################################################################################
LINUX_DSP_CONFIGS = \
	REMOTEPROC QCOM_Q6V5_PAS QCOM_SYSMON QCOM_PAS QCOM_PAS_TEE QCOM_SCM \
	RPMSG RPMSG_QCOM_GLINK RPMSG_QCOM_GLINK_SMEM QCOM_SMEM QCOM_SMP2P \
	QCOM_SMSM QCOM_IPCC QCOM_AOSS_QMP QCOM_RPMHPD QCOM_COMMAND_DB \
	QRTR QRTR_SMD QCOM_PD_MAPPER QCOM_FASTRPC \
	CMA DMA_CMA DMABUF_HEAPS DMABUF_HEAPS_SYSTEM DMABUF_HEAPS_CMA
LINUX_EXPORTS    = ARCH=arm64 CROSS_COMPILE="$(CCACHE)$(AARCH64_CROSS_COMPILE)"
LINUX_DEFCONFIG ?= defconfig
LINUX_DT         = monaco-arduino-monza
# Linux runs at EL2 with no hypervisor underneath: the EL2 overlay hands it
# the resources a hypervisor would own.
LINUX_DT_OVERLAY = monaco-el2
LINUX_DTS_DIR    = $(LINUX_PATH)/arch/arm64/boot/dts/qcom
LINUX_DTB        = $(MONACO_OUT)/$(LINUX_DT)-el2.dtb
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
		$(addprefix -e ,$(LINUX_DSP_CONFIGS))
	$(LINUX_EXPORTS) $(MAKE) -C $(LINUX_PATH) olddefconfig

# The base DTB is built with symbols (-@) so the EL2 overlay can be applied.
linux: | $(MONACO_OUT)
	@if [ ! -f $(LINUX_PATH)/.config ]; then \
		$(MAKE) -f $(firstword $(MAKEFILE_LIST)) linux-defconfig; \
	fi
	@for c in $(LINUX_DSP_CONFIGS); do \
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
# for the engines nothing earlier in the boot has set up.
################################################################################
# GitLab serves partial clones; git.kernel.org sends the whole tree.
DSP_FW_REPO   ?= https://gitlab.com/kernel-firmware/linux-firmware.git
DSP_FW_REV    ?= 664f8b6adeba20be0960d9cb1b2ad8c5a4d7e0e3
DSP_FW_FILES   = adsp.mbn adspr.jsn adspua.jsn cdsp0.mbn cdspr.jsn gpdsp0.mbn qupv3fw.elf
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
	mkdir -p $(DSP_OVERLAY)/lib/firmware/qcom/qcs8300 $(DSP_OVERLAY)/usr/share/qcom/conf.d
	cp $(DSP_OUT)/linux-firmware/LICENSE.qcom-2 $(DSP_OVERLAY)/lib/firmware/
	cp $(DSP_OUT)/linux-firmware/qcom/NOTICE.txt $(DSP_OVERLAY)/lib/firmware/qcom/
	cd $(DSP_OUT)/linux-firmware/qcom/qcs8300 && \
		cp -L $(DSP_FW_FILES) $(DSP_OVERLAY)/lib/firmware/qcom/qcs8300/
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
# monaco/input/.
################################################################################
FIREHOSE  ?= $(MONACO_IN)/prog_firehose_ddr.elf
QDL       ?= qdl
QDL_FLAGS ?= --storage emmc
TZ_MBN     = $(firstword $(wildcard $(MONACO_OUT)/tz.mbn $(MONACO_IN)/tz.mbn))

.PHONY: flash-loader flash-kernel

flash-loader:
	@[ -f "$(FIREHOSE)" ] || \
		{ echo "ERROR: firehose programmer $(FIREHOSE) missing (see monaco/input/README.md)"; exit 1; }
	@[ -n "$(TZ_MBN)" ] || \
		{ echo "ERROR: no tz.mbn: run 'make tz-qti-sign' or place a signed tz.mbn in monaco/input/"; exit 1; }
	@[ -f $(MONACO_OUT)/fip.elf ] || \
		{ echo "ERROR: monaco/output/fip.elf missing: run 'make bootimage' first"; exit 1; }
	$(QDL) $(QDL_FLAGS) $(FIREHOSE) \
		write tz_a $(TZ_MBN) write tz_b $(TZ_MBN) \
		write uefi_a $(MONACO_OUT)/fip.elf write uefi_b $(MONACO_OUT)/fip.elf

flash-kernel:
	@[ -f "$(FIREHOSE)" ] || \
		{ echo "ERROR: firehose programmer $(FIREHOSE) missing (see monaco/input/README.md)"; exit 1; }
	@[ -f $(MONACO_OUT)/efi.bin ] || \
		{ echo "ERROR: monaco/output/efi.bin missing: run 'make efi' first"; exit 1; }
	$(QDL) $(QDL_FLAGS) $(FIREHOSE) write efi $(MONACO_OUT)/efi.bin
