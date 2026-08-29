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
# NFS extraction always restores real root:root ownership (sudo) -- the
# rootfs has ~16 setuid/setgid binaries (su, passwd, busybox.suid, chage,
# chfn, chsh, expiry, gpasswd, ...) that must stay root-owned to actually
# grant root on the board.
#
# NFS safe-redeploy: set BOARD_IP to the board's IP address and --nfs-only
# (or the default "all" mode) will automatically SSH-reboot the board before
# wiping the NFS rootfs, wait for it to go down, deploy, then wait for it to
# come back up.  Without BOARD_IP, the board must be manually powered off
# before running --nfs-only (wiping a live NFS root crashes the running OS).
#
# Env overrides (defaults match this host's actual tftpd-hpa/nfs-kernel-server
# setup as of 2026-08-28):
#   DEPLOY_DIR   tmp/deploy/images/imx93frdm to read build artifacts from
#   TFTP_DIR     TFTP server root (RPi4 artifacts are purged from here on deploy)
#   NFS_DIR      real directory backing the NFS export for this board
#   BOARD_IP     board IP for SSH reboot before NFS deploy (default: 192.168.1.101)
#
# NOTE: bitbake imx-image-sec-min auto-deploys TFTP after every successful
# build (via the imx93-deploy-network bbclass). NFS deploy is manual-only,
# run from a normal shell (not from bitbake) so sudo works correctly --
# BitBake's pseudo/fakeroot wrapper interferes with sudo's ownership checks.

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
            sed -n '2,43p' "$0"
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
BOARD_IP="${BOARD_IP:-192.168.1.101}"

WIC_GZ="${DEPLOY_DIR}/${IMAGE_NAME}-${MACHINE}.rootfs.wic.gz"
ROOTFS_TAR="${DEPLOY_DIR}/${IMAGE_NAME}-${MACHINE}.rootfs.tar.zst"
KERNEL_IMAGE="${DEPLOY_DIR}/Image-${MACHINE}.bin"
DTB="${DEPLOY_DIR}/imx93-11x11-frdm-${MACHINE}.dtb"
# Machine-wide bootloader container (SPL+ATF+OP-TEE+U-Boot proper), not tied
# to any particular rootfs image -- same file regardless of sec-min/sec-full.
IMX_BOOT="${DEPLOY_DIR}/imx-boot"

_ssh_opts=(-o ConnectTimeout=3 -o StrictHostKeyChecking=no -o BatchMode=yes)

reboot_board_via_ssh() {
    local ip="$1"

    if ! ssh "${_ssh_opts[@]}" "root@$ip" true 2>/dev/null; then
        echo "==> Board at $ip not reachable via SSH -- board is already off, proceeding with NFS deploy"
        return 0
    fi

    echo "==> Sending reboot to root@$ip via SSH..."
    ssh "${_ssh_opts[@]}" "root@$ip" 'reboot' 2>/dev/null || true

    echo "==> Waiting for board to shut down..."
    local i
    for i in $(seq 1 30); do
        sleep 2
        ssh "${_ssh_opts[@]}" "root@$ip" true 2>/dev/null || { echo "==> Board is down -- safe to update NFS rootfs."; return 0; }
    done
    echo "WARNING: Board at $ip did not go down within 60s -- proceeding anyway (check it manually)"
}

wait_for_board() {
    local ip="$1"
    echo "==> Waiting for board to come back up at root@$ip ..."
    local i
    for i in $(seq 1 60); do
        sleep 5
        if ssh "${_ssh_opts[@]}" "root@$ip" true 2>/dev/null; then
            echo "==> Board is back up."
            return 0
        fi
    done
    echo "WARNING: Board at $ip did not respond within 5 minutes -- check it manually."
}

deploy_tftp() {
    [[ -f "$WIC_GZ" ]] || { echo "ERROR: $WIC_GZ not found -- build $IMAGE_NAME first" >&2; exit 1; }
    [[ -f "$KERNEL_IMAGE" ]] || { echo "ERROR: $KERNEL_IMAGE not found -- build $IMAGE_NAME first" >&2; exit 1; }
    [[ -f "$DTB" ]] || { echo "ERROR: $DTB not found -- build $IMAGE_NAME first" >&2; exit 1; }

    # Purge stale RPi4 artifacts -- RPi4 netboot is no longer served from this
    # TFTP server.  The root-level Image was the RPi4 kernel; the imx93 kernel
    # goes under imx93/Image, so the top-level one is always RPi-only.
    echo "==> Purging stale RPi4 artifacts from $TFTP_DIR/"
    if [[ -f "$TFTP_DIR/Image" ]]; then
        echo "    rm Image  (RPi4 kernel -- imx93 kernel goes to imx93/Image)"
        rm -f "$TFTP_DIR/Image"
    fi
    for f in "$TFTP_DIR"/bcm2711-*.dtb \
              "$TFTP_DIR"/*.dtbo \
              "$TFTP_DIR"/overlay_map.dtb; do
        [[ -f "$f" ]] && { echo "    rm $(basename "$f")"; rm -f "$f"; }
    done

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

    # Reboot board via SSH before wiping NFS rootfs so the board is safely
    # down when we replace its root filesystem.  Without BOARD_IP the board
    # must be manually powered off first -- wiping a live NFS root crashes it.
    if [[ -n "$BOARD_IP" ]]; then
        reboot_board_via_ssh "$BOARD_IP"
    else
        echo "NOTE: BOARD_IP not set -- make sure the board is powered off before proceeding."
        echo "      Set BOARD_IP=<ip> to have this script reboot it automatically."
    fi

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

    echo "==> Extracting $(basename "$ROOTFS_TAR") into $NFS_DIR (replaces its contents, root:root ownership)"
    # -mindepth 1 also catches dotfiles, which a plain rm -rf glob misses;
    # keeping the directory itself avoids stale NFS filehandles on clients.
    sudo find "$NFS_DIR" -mindepth 1 -delete
    sudo tar --numeric-owner -xpf "$ROOTFS_TAR" -C "$NFS_DIR"

    if [[ -n "$BOARD_IP" ]]; then
        wait_for_board "$BOARD_IP"
    fi
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
