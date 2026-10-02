################################################################################
# Video codec test userspace, for test-definitions automated/linux/video-codec:
# FFmpeg with its V4L2 mem2mem decoder and encoder wrappers, and the reference
# streams with the per-frame MD5 of their software decode in
# /usr/share/video-codec (qcom/video/mk-video-streams.sh, which needs a host
# ffmpeg with libx264, libx265 and libvpx).
#
# A board makefile sets QCOM_VIDEO_TEST = y and includes this file after its
# BR2_ROOTFS_OVERLAY assignment and after common.mk.
################################################################################
ifeq ($(QCOM_VIDEO_TEST),y)
BR2_PACKAGE_FFMPEG             = y
BR2_PACKAGE_FFMPEG_FFMPEG      = y
BR2_PACKAGE_FFMPEG_FFPROBE     = y
BR2_PACKAGE_FFMPEG_SWSCALE     = y
QCOM_VIDEO_STREAMS_DIR         ?= $(ROOT)/out/video-streams
BR2_ROOTFS_OVERLAY             += $(QCOM_VIDEO_STREAMS_DIR)

.PHONY: video-streams video-streams-clean
video-streams:
	$(CURDIR)/qcom/video/mk-video-streams.sh \
		$(QCOM_VIDEO_STREAMS_DIR)/usr/share/video-codec

video-streams-clean:
	rm -rf $(QCOM_VIDEO_STREAMS_DIR)

buildroot: video-streams
endif
