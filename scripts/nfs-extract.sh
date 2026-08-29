#!/usr/bin/env bash
# Root helper: clear and re-populate an NFS export directory from a rootfs
# tarball.  Called by the imx93-deploy-network bbclass via sudo so that file
# ownership/permissions inside the tarball are preserved without running the
# entire bitbake task as root.
#
# Usage: sudo nfs-extract.sh <rootfs.tar.zst> <nfs_dir>
#
# One-time sudoers setup (run once on the host, then forget about it):
#   SCRIPT=/home/khaled/Data/Yocto/IMX93/sources/meta-imx93-customization/scripts/nfs-extract.sh
#   chmod +x "$SCRIPT"
#   echo "khaled ALL=(ALL) NOPASSWD: $SCRIPT" | sudo tee /etc/sudoers.d/imx93-nfs-deploy
#   sudo chmod 440 /etc/sudoers.d/imx93-nfs-deploy
#
# After that, bitbake imx-image-sec-min automatically updates the NFS rootfs
# on every build.

set -euo pipefail

[[ $# -eq 2 ]] || { echo "Usage: $0 <rootfs.tar.zst> <nfs_dir>" >&2; exit 1; }

tarball="$1"
nfs_dir="$2"

# Safety: refuse to wipe well-known top-level paths.
case "$nfs_dir" in
    ""|/|/home|/home/khaled|/usr|/etc|/var|/bin|/sbin|/lib|/boot)
        echo "ERROR: refusing to operate on nfs_dir='$nfs_dir'" >&2
        exit 1
        ;;
esac

[[ -f "$tarball" ]] || { echo "ERROR: tarball not found: $tarball" >&2; exit 1; }

[[ -d "$nfs_dir" ]] || mkdir -p "$nfs_dir"

echo "==> [NFS] Clearing $nfs_dir"
rm -rf "${nfs_dir:?}"/*

echo "==> [NFS] Extracting $(basename "$tarball") into $nfs_dir"
tar --numeric-owner -xpf "$tarball" -C "$nfs_dir"

echo "==> [NFS] Done."
