swiv_build_utility.py adds the SW image version (SWIV) segment that XBL
expects in the TZ image. Arguments: the output ELF, the input ELF and the
chipset, which selects the address of the SWIV segment.

IQ-9075 EVK (lemans.mk, spl target): the U-Boot SPL is the TZ image.

    python3 qcom/security/swiv_build_utility.py \
        .output/spl/u-boot-spl-swiv.elf \
        .output/spl/u-boot-spl.elf \
        lemans

    <path_to_qtestsign>/qtestsign -v6 tz \
        -o .output/spl/u-boot-spl.mbn \
        .output/spl/u-boot-spl-swiv.elf

The resulting u-boot-spl.mbn is copied to lemans/output/tz.mbn (the tz
partition image). It is signed locally with qtestsign; no QTI CASS access or
security profile is needed.

Arduino VENTUNO Q (monaco.mk, tz-sign target): TF-A BL2 is the TZ image.
XBL checks the QTI signature of the TZ image on Monaco even with secure boot
disabled, so a qtestsign signature is not accepted; tz-sign signs it with
sectools through the QTI remote signing service:

    python3 qcom/security/swiv_build_utility.py \
        monaco/output/bl2-swiv.elf monaco/output/bl2.elf monaco

    sectools secure-image monaco/output/bl2-swiv.elf \
        --outfile monaco/output/tz.mbn --image-id TZ \
        --security-profile monaco_tz_security_profile.xml \
        --qti --sign --signing-mode QTI-REMOTE ...
