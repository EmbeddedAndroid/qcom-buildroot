#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
#
# mk-video-streams.sh <out dir>: the reference streams of the video-codec
# test (test-definitions automated/linux/video-codec) and the per-frame MD5
# of their software decode to NV12, which a hardware decode must reproduce:
#
#   h264-720p.h264   H.264 high, 1280x720, 2 B-frames, GOP 30 (x264)
#   hevc-720p.hevc   HEVC main, 1280x720, 2 B-frames, GOP 30 (x265)
#   vp9-480p.ivf     VP9 profile 0, 640x480, GOP 30 (libvpx)
#   <stream>.md5     one MD5 per decoded frame, in output order
#
# 60 frames of the FFmpeg testsrc2 pattern each. Needs a host ffmpeg with
# libx264, libx265 and libvpx (FFMPEG overrides the binary). The streams
# depend on the encoder versions; the MD5s always match the streams they
# were made from.
set -eu
out=${1:?usage: mk-video-streams.sh <out dir>}
ff=${FFMPEG:-ffmpeg}
for e in libx264 libx265 libvpx-vp9; do
	"$ff" -hide_banner -encoders 2>/dev/null | grep -q " $e " ||
		{ echo "$ff has no $e encoder" >&2; exit 1; }
done
mkdir -p "$out"
cd "$out"
src="testsrc2=size=1280x720:rate=30"
q="-hide_banner -loglevel error -y"
# shellcheck disable=SC2086
"$ff" $q -f lavfi -i "$src" -frames:v 60 -pix_fmt yuv420p \
	-c:v libx264 -profile:v high -bf 2 -g 30 -crf 23 -f h264 h264-720p.h264
# shellcheck disable=SC2086
"$ff" $q -f lavfi -i "$src" -frames:v 60 -pix_fmt yuv420p \
	-c:v libx265 -profile:v main \
	-x265-params "bframes=2:keyint=30:log-level=error:pools=none" \
	-crf 28 -f hevc hevc-720p.hevc
# shellcheck disable=SC2086
"$ff" $q -f lavfi -i "testsrc2=size=640x480:rate=30" -frames:v 60 \
	-pix_fmt yuv420p -c:v libvpx-vp9 -profile:v 0 -g 30 -b:v 1M \
	-f ivf vp9-480p.ivf
for s in h264-720p.h264 hevc-720p.hevc vp9-480p.ivf; do
	# shellcheck disable=SC2086
	"$ff" $q -i "$s" -pix_fmt nv12 -f framemd5 - |
		grep -v '^#' | awk -F, '{ gsub(/ /, "", $6); print $6 }' > "$s.md5"
	echo "$s: $(wc -c < "$s") bytes, $(wc -l < "$s.md5") frames"
done
"$ff" -hide_banner -version | head -n 1 > README
echo "60 frames of testsrc2 each; <stream>.md5: per-frame MD5 of the NV12 software decode" >> README
