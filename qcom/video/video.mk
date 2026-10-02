################################################################################
# Video codec test userspace, for test-definitions automated/linux/video-codec:
# FFmpeg with its V4L2 mem2mem decoder and encoder wrappers, and the reference
# streams with the per-frame MD5 of their software decode in
# /usr/share/video-codec (qcom/video/mk-video-streams.sh, which needs a host
# ffmpeg with libx264, libx265 and libvpx).
#
# A board makefile includes this file after its BR2_ROOTFS_OVERLAY assignment
# and after common.mk; QCOM_VIDEO_TEST=n leaves both out.
#
# FFmpeg is built with only what the test runs: the H.264, HEVC and VP9
# V4L2 mem2mem decoders and the H.264 and HEVC encoders, the software
# decoders that check a hardware encode, testsrc2 (lavfi, whose frames reach
# ffmpeg as wrapped_avframe packets), the psnr filter, framemd5 and the raw
# H.264, HEVC and IVF formats.
#
# The patches in qcom/video/buildroot-patches are applied in order to the
# Buildroot tree before it builds; one that reverses cleanly is already
# applied and is skipped.
#   0001  FFmpeg 7.1.2 instead of 6.1.2: at the end of the input the 6.1
#         ffmpeg tool holds every frame the decoder returns until it has
#         drained, so a V4L2 decoder that needs a CAPTURE buffer back to
#         finish never does (venus, H.264)
################################################################################
QCOM_VIDEO_TEST ?= y

ifeq ($(QCOM_VIDEO_TEST),y)
BR2_PACKAGE_FFMPEG             = y
BR2_PACKAGE_FFMPEG_FFMPEG      = y
BR2_PACKAGE_FFMPEG_FFPROBE     = y
BR2_PACKAGE_FFMPEG_SWSCALE     = y
BR2_PACKAGE_FFMPEG_ENCODERS    = "rawvideo wrapped_avframe h264_v4l2m2m hevc_v4l2m2m"
BR2_PACKAGE_FFMPEG_DECODERS    = "rawvideo wrapped_avframe h264 hevc vp9 h264_v4l2m2m hevc_v4l2m2m vp9_v4l2m2m"
BR2_PACKAGE_FFMPEG_MUXERS      = "framemd5 h264 hevc null rawvideo"
BR2_PACKAGE_FFMPEG_DEMUXERS    = "h264 hevc ivf rawvideo"
BR2_PACKAGE_FFMPEG_PARSERS     = "h264 hevc vp9"
BR2_PACKAGE_FFMPEG_BSFS        = "h264_mp4toannexb hevc_mp4toannexb vp9_superframe_split"
BR2_PACKAGE_FFMPEG_PROTOCOLS   = "file pipe"
BR2_PACKAGE_FFMPEG_FILTERS     = "buffer buffersink format null nullsink psnr scale testsrc2"
BR2_PACKAGE_FFMPEG_INDEVS      = n
BR2_PACKAGE_FFMPEG_OUTDEVS     = n
# configure fails if the V4L2 mem2mem support cannot be built, rather than
# leaving it out; lavfi is the input device testsrc2 needs.
BR2_PACKAGE_FFMPEG_EXTRACONF   = "--enable-v4l2-m2m --enable-indev=lavfi"
QCOM_VIDEO_STREAMS_DIR         ?= $(ROOT)/out/video-streams
BR2_ROOTFS_OVERLAY             += $(QCOM_VIDEO_STREAMS_DIR)

.PHONY: video-streams video-streams-clean
video-streams:
	$(CURDIR)/qcom/video/mk-video-streams.sh \
		$(QCOM_VIDEO_STREAMS_DIR)/usr/share/video-codec

video-streams-clean:
	rm -rf $(QCOM_VIDEO_STREAMS_DIR)

QCOM_VIDEO_BR_PATCHES = $(sort $(wildcard $(CURDIR)/qcom/video/buildroot-patches/*.patch))

.PHONY: video-buildroot-patches
video-buildroot-patches:
	@for p in $(QCOM_VIDEO_BR_PATCHES); do \
		if git -C $(ROOT)/buildroot apply -R --check $$p 2>/dev/null; then \
			echo "buildroot: $${p##*/} already applied"; \
		else \
			echo "buildroot: applying $${p##*/}"; \
			git -C $(ROOT)/buildroot apply $$p || exit 1; \
		fi; \
	done

buildroot: video-streams video-buildroot-patches
endif
