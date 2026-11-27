#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
"""mkdlme.py <out> <tramp.bin> <host.dtb> <xen> <Image> <initrd> <base>
<xen options> <dom0 cmdline> <memory banks "addr:size,...">

Pack the DRTM DLME image: the trampoline, Xen's host device tree (memory
banks, Xen's options, the dom0 kernel and initramfs as /chosen modules with
the dom0 command line), Xen, the dom0 kernel and its initramfs, laid out for
the load address <base>. The DCE measures the whole file into PCR 18."""
import os
import subprocess
import sys
import tempfile

out, tramp, dtb, xen, image, initrd = sys.argv[1:7]
base = int(sys.argv[7], 0)
xen_opts, dom0_cmd, banks = sys.argv[8:11]
M2 = 0x200000
up = lambda v, a: (v + a - 1) & ~(a - 1)

xen_off = M2
img_off = up(xen_off + os.path.getsize(xen), M2)
rd_off = up(img_off + os.path.getsize(image), M2)
# a 2 MiB multiple, the size every hardware launch so far was proven with
end = up(rd_off + os.path.getsize(initrd), M2)


def fdtput(f, *a):
    subprocess.run(["fdtput", f] + list(a), check=True)


with tempfile.TemporaryDirectory() as t:
    d = os.path.join(t, "host.dtb")
    # room for the new nodes
    subprocess.run(["dtc", "-I", "dtb", "-O", "dtb", "-p", "4096", "-o", d, dtb],
                   check=True, stderr=subprocess.DEVNULL)
    cells = []
    for b in banks.split(","):
        a, s = (int(x, 0) for x in b.split(":"))
        cells += ["%#x" % (a >> 32), "%#x" % (a & 0xffffffff),
                  "%#x" % (s >> 32), "%#x" % (s & 0xffffffff)]
    nodes = subprocess.run(["fdtget", "-l", d, "/"], check=True,
                           capture_output=True, text=True).stdout.split()
    for n in nodes:
        if n.startswith("memory"):
            subprocess.run(["fdtput", "-r", d, "/" + n], check=True)
    fdtput(d, "-c", "/memory@80000000")
    fdtput(d, "-t", "s", "/memory@80000000", "device_type", "memory")
    fdtput(d, "-t", "x", "/memory@80000000", "reg", *cells)
    if "chosen" not in nodes:
        fdtput(d, "-c", "/chosen")
    # dom0's command line is the kernel module's bootargs only
    for prop in ("bootargs", "xen,dom0-bootargs"):
        subprocess.run(["fdtput", "-d", d, "/chosen", prop],
                       stderr=subprocess.DEVNULL)
    fdtput(d, "-t", "s", "/chosen", "xen,xen-bootargs", xen_opts)
    fdtput(d, "-t", "x", "/chosen", "#address-cells", "2")
    fdtput(d, "-t", "x", "/chosen", "#size-cells", "2")
    for name, off, f, compat in (
            ("kernel", img_off, image, ["multiboot,kernel", "multiboot,module"]),
            ("ramdisk", rd_off, initrd, ["multiboot,ramdisk", "multiboot,module"])):
        n = "/chosen/module@%x" % (base + off)
        fdtput(d, "-c", n)
        fdtput(d, "-t", "s", n, "compatible", *compat)
        fdtput(d, "-t", "x", n, "reg", "%#x" % ((base + off) >> 32),
               "%#x" % ((base + off) & 0xffffffff), "0x0",
               "%#x" % os.path.getsize(f))
        if name == "kernel":
            fdtput(d, "-t", "s", n, "bootargs", dom0_cmd)
    dt = open(d, "rb").read()

if len(dt) > xen_off - 0x1000:
    sys.exit("mkdlme.py: device tree too big (%d bytes)" % len(dt))
blob = bytearray(end)
blob[0:os.path.getsize(tramp)] = open(tramp, "rb").read()
blob[0x1000:0x1000 + len(dt)] = dt
for off, f in ((xen_off, xen), (img_off, image), (rd_off, initrd)):
    data = open(f, "rb").read()
    blob[off:off + len(data)] = data
open(out, "wb").write(blob)
print("dlme.img base %#x size %#x: dt %#x xen %#x Image %#x initrd %#x" %
      (base, end, 0x1000, xen_off, img_off, rd_off))
