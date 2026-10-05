#!/bin/bash
set -euo pipefail
lease=${1:?CIL lease}
lane=${SR_LANE:-$HOME/monza/lava/sr-fold}
kit=$(dirname "$(realpath "$0")")
manifest=${SR_MANIFEST_REPO:-$HOME/monza/upstream/qcom-manifest}
mkdir -p "$lane/work"
git -C "$manifest" bundle create -q "$lane/work/qcom-manifest.bundle" all-boards
git -C "$kit/../.." bundle create -q "$lane/work/qcom-buildroot.bundle" integration-20261005-sr
read -r user host port < "$HOME/.ssh/cil-monza/$lease.host"
ssh_args=(-F /dev/null -i "$HOME/.ssh/cil-monza/$lease.key" -p "$port" -o BatchMode=yes
    -o UserKnownHostsFile="$HOME/.ssh/cil-monza/known_hosts" "$user@$host")
ssh "${ssh_args[@]}" 'mkdir -p ~/monza/sr-kit ~/monza/sr-inputs'
tar -C "$kit" -cf - cil build.sh |
    ssh "${ssh_args[@]}" 'tar -C ~/monza/sr-kit -xf -'
tar -C "$lane/work" -cf - qcom-manifest.bundle qcom-buildroot.bundle |
    ssh "${ssh_args[@]}" 'tar -C ~/monza/sr-inputs -xf -'
tar -C "$lane/build" -cf - bundles |
    ssh "${ssh_args[@]}" 'tar -C ~/monza/sr-inputs -xf -'
ssh "${ssh_args[@]}" 'bash ~/monza/sr-kit/cil/setup-vm.sh ~/monza/sr-inputs'
