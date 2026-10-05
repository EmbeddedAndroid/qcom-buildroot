# SystemReady integration builds

The integration-20261005-sr branch carries the RTC and interrupt fixes for
SystemReady DT ACS on VENTUNO Q, UNO Q, RB3 Gen 2 and Lemans EVK. Firmware
and kernel revisions are pinned in qcom/systemready/sources.json. Every
component is exported from the laptop's matching integration-20261005-sr
branch. Existing integration-20261004 sources remain unchanged.

qcom/systemready/prepare.py selects those exact revisions from local Git
bundles after manifest sync. A missing bundle or revision mismatch aborts
before a build. qcom/systemready/test_prepare.py covers source selection,
a mismatched pin and a missing bundle. test_cil_setup.py checks real bundle
imports and staging, rejects missing inputs and wrong branches, and checks
that a failed container layer stops setup. Its Docker/systemd boundary is
stubbed so these checks require no VM. Run both in monza-build:2.

The Monaco and Kodiak timer overlays use four interrupt cells because
these integration kernels already carry the PMU PPI partitions. UNO Q's
vendor kernel places the RTC property in qrb2210-arduino-imola-base.dts.
The Lemans OP-TEE overlay context follows the added RTC node; its behavior
is unchanged. The other board patches preserve the supplied SystemReady
change set.

## Recreate a CIL build

Use requester monza-sr-fold and the existing cil-build/request-lease.sh.
The VM needs Ubuntu 24.04, Git and sudo access. All compilers and build
dependencies run in the versioned qcom/systemready/cil Docker recipes,
which provide monza-build:2, monza-video:1 and monza-npu:1.

The laptop lane must contain src/qcom-buildroot and build/bundles with
the component bundles named by sources.json. With the lease connection
files in ~/.ssh/cil-monza, provision and sync it from this checkout:

    SR_LANE=$HOME/monza/lava/sr-fold bash qcom/systemready/sync.sh LEASE_ID

The script exports this branch and the local qcom-manifest all-boards
branch, transfers the versioned kit and component bundles, then runs
cil/setup-vm.sh on the VM. SR_MANIFEST_REPO can select another local
manifest checkout. Bundles stay under the lane work folder, outside /tmp.
The setup validates its bundle inputs before provisioning, installs only
Docker on the host, and builds the three container layers in order.
It stages the build entry point, workspace helper and source bundles
under ~/monza. Source selection still verifies every component revision.

Run in monza-npu:1 with the VM's ~/monza mounted at /monza, as uid/gid
1000, HOME=/monza/.home:

    bash /monza/sr/build.sh vq MONZAFP-<fresh UTC timestamp>-sr
    bash /monza/sr/build.sh kodiak RB3G2FP-<fresh UTC timestamp>-sr
    bash /monza/sr/build.sh lemans LEMANSFP-<fresh UTC timestamp>-sr

Each invocation needs a fresh fingerprint, including failed-build retries.
The script logs to /monza/logs/sr-<board>-<fingerprint>.log, finishes with
FINAL-EXIT, and collects outputs and provenance under
/monza/out/qcom-buildroot/<fingerprint>. Check log growth at least every
ten minutes. Copy the artifacts to the laptop's ~/monza/out and delete
the CIL lease when finished.

UNO Q uses the existing R52 kernel config and overlay ESP recipe.
qcom/systemready/unoq-fw.sh and unoq-linux.sh take laptop source archives
in /unoq/src-sr and fresh firmware and kernel fingerprints. The firmware
archives are named tf-a, optee_os, u-boot and qtestsign; the kernel archive
is linux with its revision in linux.revision. The kernel outputs and the
fresh VENTUNO Q rootfs feed unoq-mk-efi.sh, which emits only the standard
ESP. Give that image its own fresh fingerprint. This preserves the
integration userspace and avoids rebuilding unused command-line variants.

Sign the new BL2 images using the existing QTI signing recipes. Do not
substitute an older signed BL2 if signing fails. All hardware testing is
through public LAVA jobs submitted with lava/lava-job.py. Verify each boot
stage fingerprint before interpreting results. Use existing --systemready
generators and sr-summary.py, with the Linux 7.3 ACS image of the baseline.
Read results with limit 2000. Compare the standard plan as well as ACS.

## Limitations and workarounds

The VENTUNO Q and Lemans random Ethernet MAC fallbacks are carried
workarounds. They do not establish a persistent address or fix the Lemans
QUP firmware loading order. Lemans LAVA reset power-cycling, if used, is
also a workaround and must be reported per reset.

The supplied change set has no isolated fix for the Lemans SR-F16 SCT
driver-load abort or the rare VENTUNO Q reset hang. They remain open.
A SAIL timeout alone does not establish the VENTUNO Q hang. Diagnostic DT
changes that alter timer ranges, trimmed SCT sequences, and ACS parser
fixes are excluded from this integration.
