#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
"""dlme-pcr.py <dlme.img> <Image> <initrd> <dom0 cmdline>

Print the D-RTM PCR values a dynamic launch of dlme.img leaves in both TPM
banks (SHA-256 and SHA-384), replaying what measures them from the locality
4 reset (all zeros):

PCR 17, TF-A's DCE (services/std_svc/drtm/drtm_measurements.c): the DCE
  (0x00, no normal world DCE), the PCR schema (0x00, features 0), the
  separator "ARM_DRTM".
PCR 18, the DCE: the PCR schema, the DCE public key (0x00), the DLME image
  (its file size: U-Boot passes ${filesize}), the DLME entry point offset
  (8 zero bytes), the separator.
PCR 19, Xen (xen/arch/arm/drtm.c, drtm-tpm=): one event per dom0 object
  whose data is the object's SHA-256: the kernel, the initramfs, the
  command line without its NUL.

Each event extends PCR = H(PCR || H(data)) in its bank."""
import hashlib
import sys

dlme_f, image_f, initrd_f, cmdline = sys.argv[1:5]
dlme = open(dlme_f, "rb").read()
schema, sep = b"\0", b"ARM_DRTM"
dom0 = [hashlib.sha256(open(f, "rb").read()).digest() for f in (image_f, initrd_f)]
dom0.append(hashlib.sha256(cmdline.encode()).digest())
pcrs = {17: [b"\0", schema, sep], 18: [schema, b"\0", dlme, bytes(8), sep], 19: dom0}
for bank, h in (("sha256", hashlib.sha256), ("sha384", hashlib.sha384)):
    for pcr, events in pcrs.items():
        v = bytes(h().digest_size)
        for e in events:
            v = h(v + h(e).digest()).digest()
        print("PCR %s %d %s" % (bank, pcr, v.hex().upper()))
