#!/bin/bash
set -euo pipefail
inputs=${1:?directory containing source bundles}
monza_root=${SR_VM_ROOT:-$HOME/monza}
kit=$(dirname "$(realpath "$0")")
branch=integration-20261005-sr

for file in qcom-manifest.bundle qcom-buildroot.bundle; do
    if [ ! -s "$inputs/$file" ]; then
        echo "missing input: $file" >&2
        exit 1
    fi
done
if [ ! -d "$inputs/bundles" ]; then
    echo "missing input: bundles" >&2
    exit 1
fi
inputs=$(realpath "$inputs")
cd "$inputs"
if ! git bundle list-heads qcom-manifest.bundle refs/heads/all-boards |
    grep -q ' refs/heads/all-boards$'; then
    echo 'manifest bundle lacks all-boards' >&2
    exit 1
fi
if ! git bundle list-heads qcom-buildroot.bundle "refs/heads/$branch" |
    grep -q " refs/heads/$branch$"; then
    echo "build bundle lacks $branch" >&2
    exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y docker.io docker-compose-v2
fi
sudo systemctl enable --now docker
mkdir -p "$monza_root"/{src/build,qb,qb-git,qb-tools,sr/bundles,out,logs,.home}
git config -f "$monza_root/.home/.gitconfig" user.name 'Tyler Baker'
git config -f "$monza_root/.home/.gitconfig" user.email tyler.baker@oss.qualcomm.com
git config -f "$monza_root/.home/.gitconfig" color.ui false

for project in qcom-manifest qcom-buildroot; do
    git init -q --bare "$monza_root/qb-git/$project.git"
done
git -C "$monza_root/qb-git/qcom-manifest.git" fetch -q \
    "$inputs/qcom-manifest.bundle" all-boards:refs/heads/ventuno-q
git -C "$monza_root/qb-git/qcom-buildroot.git" fetch -q \
    "$inputs/qcom-buildroot.bundle" "$branch:refs/heads/$branch"
install -m 755 "$kit/vm-workspace.sh" "$monza_root/qb-tools/vm-workspace.sh"
install -m 755 "$kit/../build.sh" "$monza_root/sr/build.sh"
cp -a "$inputs/bundles/." "$monza_root/sr/bundles/"

for service in build video npu; do
    sudo env MONZA_ROOT="$monza_root" docker compose -f "$kit/compose.yaml" build "$service"
done
sudo env MONZA_ROOT="$monza_root" docker compose -f "$kit/compose.yaml" \
    run --rm npu bash -c 'command -v make git repo python3 ukify mkfs.fat mcopy aarch64-linux-gnu-gcc ffmpeg'
echo 'SystemReady CIL environment ready'
