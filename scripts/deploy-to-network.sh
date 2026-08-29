#!/usr/bin/env bash
# Deploy a built imx93frdm image to this host's TFTP/NFS servers, so the
# board can either:
#   - flash it: `run netflash` at the U-Boot prompt (this layer's
#     0020-imx93_frdm-Add-network-image-flash.patch) fetches the .wic.gz
#     over TFTP and raw-writes it to the SD card.
#   - load it live, no flashing: `run netboot` (built into meta-imx-frdm's
#     board support, root=/dev/nfs) fetches the kernel+dtb over TFTP and
#     mounts the rootfs over NFS. See the README section this script is
#     documented under for the one-time U-Boot `setenv` sequence needed.
#
# Usage:
#   deploy-to-network.sh [sec-min|sec-full] [--tftp-only|--nfs-only]
#
# Env overrides (defaults match this host's actual tftpd-hpa/nfs-kernel-server
# setup as of 2026-08-28):
#   DEPLOY_DIR   tmp/deploy/images/imx93frdm to read build artifacts from
#   TFTP_DIR     TFTP server root
#   NFS_DIR      real directory backing the NFS export for this board

set -euo pipefail

MACHINE="imx93frdm"
IMAGE_NAME="imx-image-sec-min"
MODE="all"

for arg in "$@"; do
    case "$arg" in
        sec-min|imx-image-sec-min) IMAGE_NAME="imx-image-sec-min" ;;
        sec-full|imx-image-sec-full) IMAGE_NAME="imx-image-sec-full" ;;
        --tftp-only) MODE="tftp" ;;
        --nfs-only) MODE="nfs" ;;
        -h|--help)
            sed -n '2,20p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

DEPLOY_DIR="${DEPLOY_DIR:-/home/khaled/Data/Yocto/IMX93/frdm-imx93/tmp/deploy/images/${MACHINE}}"
TFTP_DIR="${TFTP_DIR:-/home/khaled/Documents/Network/TFTP}"
NFS_DIR="${NFS_DIR:-/home/khaled/Documents/Network/NFS-IMX93}"
NFS_EXPORT_LINK="/exports/imx93"

WIC_GZ="${DEPLOY_DIR}/${IMAGE_NAME}-${MACHINE}.rootfs.wic.gz"
ROOTFS_TAR="${DEPLOY_DIR}/${IMAGE_NAME}-${MACHINE}.rootfs.tar.zst"
KERNEL_IMAGE="${DEPLOY_DIR}/Image-${MACHINE}.bin"
DTB="${DEPLOY_DIR}/imx93-11x11-frdm-${MACHINE}.dtb"

deploy_tftp() {
    [[ -f "$WIC_GZ" ]] || { echo "ERROR: $WIC_GZ not found -- build $IMAGE_NAME first" >&2; exit 1; }
    [[ -f "$KERNEL_IMAGE" ]] || { echo "ERROR: $KERNEL_IMAGE not found -- build $IMAGE_NAME first" >&2; exit 1; }
    [[ -f "$DTB" ]] || { echo "ERROR: $DTB not found -- build $IMAGE_NAME first" >&2; exit 1; }

    echo "==> TFTP root ($TFTP_DIR) is shared with other boards, e.g. the"
    echo "    RPi4 netboot setup, which also uses a generic 'Image' filename."
    echo "    Kernel+dtb go under imx93/ to avoid clobbering that."

    echo "==> $(basename "$WIC_GZ") -> $TFTP_DIR/ (for: run netflash)"
    install -m 0644 "$WIC_GZ" "$TFTP_DIR/"

    mkdir -p "$TFTP_DIR/imx93"
    echo "==> Image, imx93-11x11-frdm.dtb -> $TFTP_DIR/imx93/ (for: run netboot)"
    install -m 0644 "$KERNEL_IMAGE" "$TFTP_DIR/imx93/Image"
    install -m 0644 "$DTB" "$TFTP_DIR/imx93/imx93-11x11-frdm.dtb"
}

deploy_nfs() {
    [[ -f "$ROOTFS_TAR" ]] || { echo "ERROR: $ROOTFS_TAR not found -- build $IMAGE_NAME first" >&2; exit 1; }

    case "$NFS_DIR" in
        ""|/|/home|/home/khaled) echo "ERROR: refusing to operate on NFS_DIR='$NFS_DIR'" >&2; exit 1 ;;
    esac

    if [[ ! -d "$NFS_DIR" ]]; then
        echo "==> Creating $NFS_DIR"
        mkdir -p "$NFS_DIR"
    fi

    if ! grep -qs "^${NFS_EXPORT_LINK}[[:space:]]" /etc/exports 2>/dev/null; then
        echo "NOTE: $NFS_EXPORT_LINK isn't in /etc/exports yet -- one-time setup:"
        echo "  sudo ln -sfn $NFS_DIR $NFS_EXPORT_LINK"
        echo "  echo '$NFS_EXPORT_LINK *(rw,sync,no_subtree_check,no_root_squash,insecure)' | sudo tee -a /etc/exports"
        echo "  sudo exportfs -ra"
        echo "(mirrors the existing /exports/raspi4 entry)"
    fi

    echo "==> Extracting $(basename "$ROOTFS_TAR") into $NFS_DIR (replaces its contents)"
    sudo rm -rf "${NFS_DIR:?}"/*
    sudo tar --numeric-owner -xpf "$ROOTFS_TAR" -C "$NFS_DIR"
}

case "$MODE" in
    tftp) deploy_tftp ;;
    nfs) deploy_nfs ;;
    all) deploy_tftp; deploy_nfs ;;
esac

echo "Done."
