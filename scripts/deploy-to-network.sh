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
# It can also bootstrap a blank SD card with just the bootloader (see
# --flash-boot below), so the very first flash doesn't need a full image at
# all -- only enough to reach the U-Boot prompt and take it from there over
# the network.
#
# Usage:
#   deploy-to-network.sh [sec-min|sec-full] [--tftp-only|--nfs-only]
#   deploy-to-network.sh --flash-boot /dev/sdX
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
FLASH_BOOT_DEV=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        sec-min|imx-image-sec-min) IMAGE_NAME="imx-image-sec-min" ;;
        sec-full|imx-image-sec-full) IMAGE_NAME="imx-image-sec-full" ;;
        --tftp-only) MODE="tftp" ;;
        --nfs-only) MODE="nfs" ;;
        --flash-boot)
            shift
            [[ $# -gt 0 ]] || { echo "ERROR: --flash-boot needs a device path, e.g. /dev/sdb" >&2; exit 1; }
            MODE="flash-boot"
            FLASH_BOOT_DEV="$1"
            ;;
        -h|--help)
            sed -n '2,24p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
    shift
done

DEPLOY_DIR="${DEPLOY_DIR:-/home/khaled/Data/Yocto/IMX93/frdm-imx93/tmp/deploy/images/${MACHINE}}"
TFTP_DIR="${TFTP_DIR:-/home/khaled/Documents/Network/TFTP}"
NFS_DIR="${NFS_DIR:-/home/khaled/Documents/Network/NFS-IMX93}"
NFS_EXPORT_LINK="/exports/imx93"

WIC_GZ="${DEPLOY_DIR}/${IMAGE_NAME}-${MACHINE}.rootfs.wic.gz"
ROOTFS_TAR="${DEPLOY_DIR}/${IMAGE_NAME}-${MACHINE}.rootfs.tar.zst"
KERNEL_IMAGE="${DEPLOY_DIR}/Image-${MACHINE}.bin"
DTB="${DEPLOY_DIR}/imx93-11x11-frdm-${MACHINE}.dtb"
# Machine-wide bootloader container (SPL+ATF+OP-TEE+U-Boot proper), not tied
# to any particular rootfs image -- same file regardless of sec-min/sec-full.
IMX_BOOT="${DEPLOY_DIR}/imx-boot"

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

deploy_flash_boot() {
    local dev="$1"
    local part dev_sectors

    [[ -f "$IMX_BOOT" ]] || { echo "ERROR: $IMX_BOOT not found -- build any image at least once first (imx-boot is a machine-level artifact, produced regardless of which image recipe triggers it)" >&2; exit 1; }
    [[ -b "$dev" ]] || { echo "ERROR: $dev is not a block device" >&2; exit 1; }

    # Refuse to touch whatever disk backs this host's own root filesystem.
    local root_src root_disk
    root_src="$(findmnt -no SOURCE / 2>/dev/null || true)"
    root_disk="$(lsblk -no pkname "$root_src" 2>/dev/null || true)"
    if [[ -n "$root_disk" && "$dev" == "/dev/$root_disk" ]]; then
        echo "ERROR: $dev backs this host's own root filesystem -- refusing" >&2
        exit 1
    fi

    echo "==> This ERASES ALL EXISTING PARTITIONS on $dev (wipefs + zeroed"
    echo "    partition table/boot area/environment sector), then writes"
    echo "    ONLY the bootloader (imx-boot: SPL+ATF+OP-TEE+U-Boot) at byte"
    echo "    offset 32KiB (bs=1K seek=32), matching this board's .wks"
    echo "    layout. No partition table, no /boot, no rootfs afterward."
    echo "    The board will power up straight to the U-Boot prompt with"
    echo "    nothing else on the card -- use 'run netboot' or 'run netflash'"
    echo "    from there to get a kernel/rootfs over the network."
    echo "    (A card with old partitions left in place has previously been"
    echo "    observed getting one of them auto-mounted read-write by the"
    echo "    booted OS -- wiping first avoids that.)"
    echo
    lsblk "$dev" 2>/dev/null || true
    echo
    read -rp "Type YES to ERASE ALL PARTITIONS on $dev and write $IMX_BOOT: " confirm
    [[ "$confirm" == "YES" ]] || { echo "Aborted, nothing written."; exit 1; }

    # Unmount anything the host may have auto-mounted from this card.
    for part in "${dev}"?*; do
        [[ -b "$part" ]] && sudo umount "$part" 2>/dev/null
    done

    echo "==> Wiping partition table and filesystem signatures on $dev"
    sudo wipefs -a "$dev"
    # Zero the first 8MiB (covers MBR + the whole imx-boot/env gap before
    # /boot per this board's .wks, CONFIG_ENV_OFFSET=0x700000 included) and
    # the last 1MiB (covers a stray backup GPT header, if one ever existed).
    sudo dd if=/dev/zero of="$dev" bs=1M count=8 conv=fsync status=none
    dev_sectors="$(sudo blockdev --getsz "$dev" 2>/dev/null || echo 0)"
    if [[ "$dev_sectors" -gt 2048 ]]; then
        sudo dd if=/dev/zero of="$dev" bs=512 seek=$((dev_sectors - 2048)) count=2048 conv=fsync status=none
    fi

    echo "==> Writing $IMX_BOOT to $dev at offset 32KiB"
    sudo dd if="$IMX_BOOT" of="$dev" bs=1K seek=32 conv=fsync status=progress
    echo "Done -- $dev erased and imx-boot written."
}

case "$MODE" in
    tftp) deploy_tftp ;;
    nfs) deploy_nfs ;;
    all) deploy_tftp; deploy_nfs ;;
    flash-boot) deploy_flash_boot "$FLASH_BOOT_DEV" ;;
esac

echo "Done."
