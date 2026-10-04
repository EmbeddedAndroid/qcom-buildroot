################################################################################
# GPU userspace, for test-definitions automated/linux/gpu-render and the GPU
# and TensorFlow Lite entries of automated/linux/inference:
#   - Mesa freedreno with EGL, OpenGL ES and GBM, and egl-readback, which
#     renders on the GPU and checks the pixels it reads back;
#   - OpenCL from Mesa RustiCL on freedreno, with the ICD loader and clinfo;
#     Mesa 25.2 enables the freedreno device in RustiCL by default;
#   - TensorFlow Lite with XNNPACK and its GPU delegate (OpenCL backend), and
#     tflite-run, which the inference test drives on the CPU and the GPU.
# The GPU firmware (SQE microcode and GMU firmware) comes from the board
# makefile, which stages it from linux-firmware; no zap shader is needed, as
# the EL2 overlays of the board device trees disable it.
#
# A board makefile includes this file after its BR2_ROOTFS_OVERLAY assignment
# and after common.mk; QCOM_GPU=n leaves the GPU userspace out.
#
# The rootfs is the initramfs: post-build.sh removes the developer tools and
# data these packages install that nothing on the target uses (other libclc
# targets, libclang, the SPIRV tools, the Vulkan registry, flatc).
#
# Buildroot patches: qcom/gpu/buildroot-patches/*.patch, applied in order to
# the Buildroot tree (common.xml pins 2025.05) before it builds. The last patch
# that reverses cleanly marks the end of what is already applied (a later
# patch can change the context of an earlier one, so earlier ones need not
# reverse); the patches after it are applied.
#   0001  Mesa 25.1.8 from Buildroot 2025.08; Mesa 25.0 does not know the
#         Adreno 623
#   0002  opencl-headers and
#   0003  opencl-icd-loader, from Buildroot 2025.08
#   0004  Mesa RustiCL from Buildroot 2025.08
#   0005  RustiCL on freedreno
#   0006  the TensorFlow Lite GPU delegate (OpenCL backend)
#   0007  XNNPACK on AArch64 (TensorFlow Lite's CPU path)
#   0008  SPIRV-Headers and SPIRV-Tools 1.3.280.0 (2024.1, which Mesa's
#         OpenCL C compiler needs) and a SPIRV-LLVM-Translator v15 that
#         builds against them
#   0009  the TensorFlow Lite GPU delegate aligns image pitch in pixels, as
#         OpenCL defines it (it divides by the bytes per pixel on Adreno,
#         which Mesa RustiCL rejects once it offers images on buffers)
#   0010  rust-bindgen 0.72.0 from Buildroot 2025.08 (Mesa 25.2 RustiCL needs
#         0.71.1 or newer)
#   0011  Mesa 25.2.8: the 25.2 series is the first whose freedreno knows
#         the Adreno 702 (Arduino UNO Q), so every board shares one Mesa
# An existing output directory keeps the Mesa it built without OpenCL:
# make mesa3d-dirclean there after enabling it.
################################################################################
QCOM_GPU ?= y

ifeq ($(QCOM_GPU),y)
BR2_PACKAGE_MESA3D                          = y
BR2_PACKAGE_MESA3D_GALLIUM_DRIVER_FREEDRENO = y
BR2_PACKAGE_MESA3D_OPENGL_EGL               = y
BR2_PACKAGE_MESA3D_OPENGL_ES                = y
BR2_PACKAGE_MESA3D_GBM                      = y
BR2_PACKAGE_LIBDRM                          = y
BR2_PACKAGE_EGL_READBACK_EXT                = y
BR2_PACKAGE_MESA3D_LLVM                     = y
BR2_PACKAGE_MESA3D_OPENCL                   = y
BR2_PACKAGE_MESA3D_RUSTICL                  = y
BR2_PACKAGE_CLINFO                          = y
BR2_PACKAGE_TENSORFLOW_LITE                 = y
BR2_PACKAGE_TENSORFLOW_LITE_GPU             = y
BR2_PACKAGE_TFLITE_RUN_EXT                  = y
BR2_ROOTFS_POST_BUILD_SCRIPT                = $(CURDIR)/qcom/gpu/post-build.sh

QCOM_GPU_BR_PATCHES ?= $(sort $(wildcard $(CURDIR)/qcom/gpu/buildroot-patches/*.patch))

.PHONY: gpu-buildroot-patches
gpu-buildroot-patches:
	@n=0; i=0; \
	for p in $(QCOM_GPU_BR_PATCHES); do \
		i=$$((i + 1)); \
		git -C $(ROOT)/buildroot apply -R --check $$p 2>/dev/null && n=$$i; \
	done; \
	i=0; \
	for p in $(QCOM_GPU_BR_PATCHES); do \
		i=$$((i + 1)); \
		if [ $$i -le $$n ]; then \
			echo "buildroot: $${p##*/} already applied"; \
		else \
			echo "buildroot: applying $${p##*/}"; \
			git -C $(ROOT)/buildroot apply $$p || exit 1; \
		fi; \
	done

buildroot: gpu-buildroot-patches
endif
