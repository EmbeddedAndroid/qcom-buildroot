#!/bin/bash
# vm-workspace.sh <monaco|lemans> [build-branch] [workspace]: create or
# resync the repo workspace /monza/qb/<workspace> (default: the board name)
# in the build container on the CIL VM.
# Runs repo against the local manifest branch ventuno-q in
# /monza/qb-git/qcom-manifest.git and replaces the build project with the
# local qcom-buildroot branch (default ventuno-q), so unmerged changes can
# be built exactly as the manifest describes them.
set -euo pipefail
board=${1:?usage: vm-workspace.sh <monaco|lemans> [build-branch] [workspace]}
branch=${2:-ventuno-q}
ws=/monza/qb/${3:-$board}
mkdir -p "$ws" && cd "$ws"
if [ ! -d .repo ]; then
	repo init -q -u /monza/qb-git/qcom-manifest.git -b ventuno-q -m "$board.xml"
fi
mkdir -p .repo/local_manifests
cat > .repo/local_manifests/local.xml <<XML
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remote name="local" fetch="file:///monza/qb-git" />
  <remove-project name="qcom-buildroot.git" />
  <project path="build" remote="local" name="qcom-buildroot.git" revision="$branch">
    <linkfile src="$board.mk" dest="build/Makefile" />
  </project>
</manifest>
XML
repo sync -j8 --no-clone-bundle --force-sync
repo manifest -r -o "$ws/manifest-pinned.xml"
