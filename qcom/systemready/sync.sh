#!/bin/bash
set -euo pipefail
lease=${1:?CIL lease}
lane=${SR_LANE:-$HOME/monza/lava/sr-fold}
export PATH="$lane/build/bin:$PATH"
export TMPDIR="$lane/work"
QB_BRANCH=integration-20261005-sr SYNC_ONLY=1 bash "$HOME/monza/lava/npu/build/vm-setup.sh" "$lease"
read -r user host port < "$HOME/.ssh/cil-monza/$lease.host"
ssh_args=(-i "$HOME/.ssh/cil-monza/$lease.key" -p "$port" -o BatchMode=yes
    -o UserKnownHostsFile="$HOME/.ssh/cil-monza/known_hosts" "$user@$host")
ssh "${ssh_args[@]}" 'mkdir -p ~/monza/sr'
tar -C "$lane/build" -cf - bundles |
    ssh "${ssh_args[@]}" 'tar -C ~/monza/sr -xf -'
tar -C "$lane/src/qcom-buildroot/qcom/systemready" -cf - build.sh |
    ssh "${ssh_args[@]}" 'tar -C ~/monza/sr -xf -'
