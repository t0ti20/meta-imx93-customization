# Copyright 2026
# Released under the MIT license (see COPYING.MIT for the terms)

DESCRIPTION = "Minimal headless security-testing image for i.MX93 FRDM: SSH, Python3, WiFi/Ethernet, AHAB/ELE/OP-TEE/TPM2 tooling. No graphics, no SELinux."

LICENSE = "MIT"

inherit core-image imx93-welcome-banner imx93-deploy-network

IMAGE_LINGUAS = " "

# Passwordless root login (debug-tweaks, on by default) is kept intentionally:
# this is a hands-on security-testing image, not a production image, so easy
# root access on the serial console/SSH is wanted rather than a password gate.
IMAGE_FEATURES += "ssh-server-openssh"

# gzip-compressed .wic alongside the default .wic.zst: U-Boot's netflash
# command (see meta-imx93-customization's u-boot-imx bbappend) only has
# gzip decompression available, no zstd CLI command.
IMAGE_FSTYPES += "wic.gz"

IMAGE_INSTALL = "packagegroup-core-boot ${CORE_IMAGE_EXTRA_INSTALL}"

IMAGE_INSTALL += " \
    kernel-modules \
    util-linux \
    coreutils \
    e2fsprogs-mke2fs \
    e2fsprogs-resize2fs \
    mmc-utils \
    mtd-utils \
    u-boot-fw-utils \
    \
    python3 \
    python3-pip \
    python3-cryptography \
    \
    ethtool net-tools iproute2 iptables tcpdump bridge-utils \
    wpa-supplicant wireless-regdb-static hostapd wireless-tools \
    nxp-wlan-sdk kernel-module-nxp-wlan \
    firmware-nxp-wifi-nxpiw610-sdio firmware-nxp-wifi-nxpiw612-sdio \
    \
    packagegroup-imx-security \
    packagegroup-fsl-optee-imx \
    packagegroup-security-tpm2 \
    openssl \
    \
    strace gdb vim htop \
    udev-extraconf \
"

export IMAGE_BASENAME = "imx-image-sec-min"
