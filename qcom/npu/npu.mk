################################################################################
# NPU test model, for test-definitions automated/linux/npu-qnn: MobileNetV2 as
# two QAIRT DLCs (fp32 for the QNN CPU backend, 8-bit for the HTP), seven
# public domain or CC0 test images preprocessed to the model input, the
# expected classes and the x86 reference outputs, in /usr/share/npu-qnn/model
# (qcom/npu/mk-npu-model.sh: pinned public inputs; the QAIRT SDK is fetched
# from Qualcomm and used on the build host only, never put in the image).
# The test fetches the QAIRT runtime itself at run time; the FastRPC
# userspace and the DSP runtime come from the board makefile.
#
# A board makefile includes this file after its BR2_ROOTFS_OVERLAY assignment
# and after common.mk; QCOM_NPU_TEST=n leaves the model out (the test then
# skips). Building the model needs an x86_64 host (see mk-npu-model.sh).
################################################################################
QCOM_NPU_TEST ?= y

ifeq ($(QCOM_NPU_TEST),y)
QCOM_NPU_MODEL_DIR ?= $(ROOT)/out/npu-model
BR2_ROOTFS_OVERLAY += $(QCOM_NPU_MODEL_DIR)

.PHONY: npu-model npu-model-clean
npu-model:
	NPU_CACHE=$(ROOT)/out/npu-cache $(CURDIR)/qcom/npu/mk-npu-model.sh \
		$(QCOM_NPU_MODEL_DIR)/usr/share/npu-qnn/model

npu-model-clean:
	rm -rf $(QCOM_NPU_MODEL_DIR) $(ROOT)/out/npu-cache

buildroot: npu-model
endif
