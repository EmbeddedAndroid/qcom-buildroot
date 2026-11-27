/* SPDX-License-Identifier: BSD-2-Clause */
/*
 * Head of dlme.img. The DRTM DCE enters the DLME at EL2 with the MMU and
 * caches off, x0 = DLME region base and x1 = DLME data offset. Xen's arm64
 * entry follows the Linux boot protocol: x0 = its device tree, x1-x3 = 0.
 * mkdlme.py puts the device tree at +0x1000 and Xen at +0x200000.
 */
	.text
	.globl	_start
_start:
	adr	x0, _start + 0x1000
	mov	x1, xzr
	mov	x2, xzr
	mov	x3, xzr
	b	_start + 0x200000
