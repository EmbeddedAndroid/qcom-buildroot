################################################################################
#
# tflite_run_ext
#
# tflite-run (src/tflite-run.cc): TensorFlow Lite on a list of raw inputs,
# XNNPACK on the CPU or the GPU delegate, for the inference test.
#
################################################################################

TFLITE_RUN_EXT_VERSION = 1.0
TFLITE_RUN_EXT_SITE = $(BR2_EXTERNAL_OPTEE_PATH)/package/tflite_run_ext/src
TFLITE_RUN_EXT_SITE_METHOD = local
TFLITE_RUN_EXT_LICENSE = BSD-2-Clause
TFLITE_RUN_EXT_DEPENDENCIES = tensorflow-lite

ifeq ($(BR2_PACKAGE_TENSORFLOW_LITE_GPU),)
TFLITE_RUN_EXT_CXXFLAGS += -DTFLITE_RUN_NO_GPU
endif
ifeq ($(BR2_PACKAGE_XNNPACK),)
TFLITE_RUN_EXT_CXXFLAGS += -DTFLITE_RUN_NO_XNNPACK
endif

define TFLITE_RUN_EXT_BUILD_CMDS
	$(TARGET_CXX) $(TARGET_CXXFLAGS) $(TARGET_LDFLAGS) -std=c++17 -Wall \
		$(TFLITE_RUN_EXT_CXXFLAGS) -o $(@D)/tflite-run $(@D)/tflite-run.cc \
		-ltensorflow-lite
endef

define TFLITE_RUN_EXT_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/tflite-run $(TARGET_DIR)/usr/bin/tflite-run
endef

$(eval $(generic-package))
