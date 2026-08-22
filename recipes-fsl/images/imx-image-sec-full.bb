# Copyright 2026
# Released under the MIT license (see COPYING.MIT for the terms)

require imx-image-sec-min.bb

DESCRIPTION = "Full security-testing image for i.MX93 FRDM: everything in imx-image-sec-min, \
plus CAN bus, HSM/PKCS11 tooling, and a broad suite of userspace security-testing tools \
(WiFi auditing, host IDS/integrity, compliance scanning, filesystem encryption, SSH hardening, \
network auditing). No graphics, no SELinux, no machine learning."

IMAGE_INSTALL += " \
    can-utils \
    \
    softhsm \
    opensc \
    pkcs11-provider \
    libp11 \
    packagegroup-security-parsec \
    swtpm \
    \
    aircrack-ng \
    checksec \
    aide \
    openscap \
    scap-security-guide \
    sshguard \
    ncrack \
    suricata \
    arpwatch \
    \
    google-authenticator-libpam \
    fscrypt \
    fscryptctl \
    ecryptfs-utils \
    cryptmount \
    paxctl \
    clamav \
"

export IMAGE_BASENAME = "imx-image-sec-full"
