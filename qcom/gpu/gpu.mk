################################################################################
# GPU userspace, for test-definitions automated/linux/gpu-render and the GPU
# and TensorFlow Lite entries of automated/linux/inference, as the VENTUNO Q
# (monaco.mk) builds it:
#   - Mesa freedreno with EGL, OpenGL ES and GBM, and egl-readback, which
#     renders on the GPU and checks the pixels it reads back;
#   - OpenCL from Mesa RustiCL on freedreno, with the ICD loader and clinfo;
#     Mesa 25.1 exposes the freedreno device to OpenCL only when
#     RUSTICL_ENABLE names it (qcom/gpu/overlay/etc/profile.d/rusticl.sh);
#   - TensorFlow Lite with XNNPACK and its GPU delegate (OpenCL backend), and
#     tflite-run, which the inference test drives on the CPU and the GPU.
# The GPU firmware (SQE microcode and GMU firmware) comes from the board
# makefile, which stages it from linux-firmware; no zap shader is needed, as
# the EL2 overlays of the board device trees disable it.
#
# A board makefile includes this file after its BR2_ROOTFS_OVERLAY assignment
# and after common.mk; QCOM_GPU=n leaves the GPU userspace out.
#
# The Buildroot patches are the VENTUNO Q series in monaco/buildroot-patches
# (the Mesa that knows the Adreno 6xx GPUs of these boards, RustiCL and its
# dependencies, the TensorFlow Lite GPU delegate, XNNPACK on AArch64; see
# monaco.mk), so every board builds the same Mesa. They are applied in order
# to the Buildroot tree before it builds: the last patch that reverses
# cleanly marks the end of what is already applied, the rest is applied.
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
BR2_ROOTFS_OVERLAY                         += $(CURDIR)/qcom/gpu/overlay

QCOM_GPU_BR_PATCHES ?= $(sort $(wildcard $(CURDIR)/monaco/buildroot-patches/*.patch))

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
