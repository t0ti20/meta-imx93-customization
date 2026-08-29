# Auto-deploys freshly built IMX93 FRDM artifacts to the host's TFTP and NFS
# servers after every successful do_image_complete.
#
# TFTP deploy: no sudo -- user owns the TFTP directory.
# NFS deploy:  needs root for correct file ownership inside the tarball.
#              Uses a dedicated helper script (scripts/nfs-extract.sh) via a
#              single passwordless sudoers rule.
#
# ── ONE-TIME HOST SETUP (run once, then bitbake handles everything) ──────────
#   SCRIPT="${IMX93_CUSTOMIZATION_LAYERDIR}/scripts/nfs-extract.sh"
#   chmod +x "$SCRIPT"
#   echo "khaled ALL=(ALL) NOPASSWD: $SCRIPT" \
#       | sudo tee /etc/sudoers.d/imx93-nfs-deploy
#   sudo chmod 440 /etc/sudoers.d/imx93-nfs-deploy
# ────────────────────────────────────────────────────────────────────────────
#
# TFTP layout after deploy:
#   $IMX93_TFTP_DIR/
#     imx-image-sec-*-imx93frdm.rootfs.wic.gz   (for U-Boot: run netflash)
#     imx93/
#       Image                                     (for U-Boot: run netboot)
#       imx93-11x11-frdm.dtb
#
# Override any variable below in local.conf if your paths differ.

IMX93_TFTP_DIR          ?= "/home/khaled/Documents/Network/TFTP"
IMX93_NFS_DIR           ?= "/home/khaled/Documents/Network/NFS-IMX93"
IMX93_NFS_EXTRACT_SCRIPT ?= "${IMX93_CUSTOMIZATION_LAYERDIR}/scripts/nfs-extract.sh"

do_deploy_network() {
    tftp_dir="${IMX93_TFTP_DIR}"
    nfs_dir="${IMX93_NFS_DIR}"
    nfs_script="${IMX93_NFS_EXTRACT_SCRIPT}"
    deploy_dir="${DEPLOY_DIR_IMAGE}"

    # =========================================================================
    # TFTP deploy (no sudo needed)
    # =========================================================================
    if [ ! -d "$tftp_dir" ]; then
        bbwarn "do_deploy_network: IMX93_TFTP_DIR=$tftp_dir does not exist -- skipping TFTP deploy"
    else
        # Purge stale RPi4 artifacts from TFTP root.
        # Top-level Image was the RPi4 kernel; imx93 kernel lives under imx93/.
        bbplain "==> [IMX93-DEPLOY] Purging stale RPi4 artifacts from $tftp_dir/"
        if [ -f "$tftp_dir/Image" ]; then
            bbplain "    rm Image  (RPi4 kernel)"
            rm -f "$tftp_dir/Image"
        fi
        for f in "$tftp_dir"/bcm2711-*.dtb \
                  "$tftp_dir"/*.dtbo \
                  "$tftp_dir"/overlay_map.dtb; do
            [ -f "$f" ] && { bbplain "    rm $(basename "$f")"; rm -f "$f"; }
        done

        # WIC.gz -- fetched by U-Boot: run netflash
        wic_gz="${deploy_dir}/${IMAGE_BASENAME}-${MACHINE}.rootfs.wic.gz"
        if [ -f "$wic_gz" ]; then
            bbplain "==> [IMX93-DEPLOY] $(basename "$wic_gz") -> $tftp_dir/"
            install -m 0644 "$wic_gz" "$tftp_dir/"
        else
            bbwarn "do_deploy_network: WIC.gz not found (IMAGE_FSTYPES += wic.gz required): $wic_gz"
        fi

        # Kernel + DTB -- fetched by U-Boot: run netboot
        mkdir -p "$tftp_dir/imx93"
        kernel="${deploy_dir}/Image-${MACHINE}.bin"
        if [ -f "$kernel" ]; then
            bbplain "==> [IMX93-DEPLOY] Image-${MACHINE}.bin -> $tftp_dir/imx93/Image"
            install -m 0644 "$kernel" "$tftp_dir/imx93/Image"
        else
            bbwarn "do_deploy_network: kernel image not found: $kernel"
        fi
        dtb="${deploy_dir}/imx93-11x11-frdm-${MACHINE}.dtb"
        if [ -f "$dtb" ]; then
            bbplain "==> [IMX93-DEPLOY] imx93-11x11-frdm-${MACHINE}.dtb -> $tftp_dir/imx93/imx93-11x11-frdm.dtb"
            install -m 0644 "$dtb" "$tftp_dir/imx93/imx93-11x11-frdm.dtb"
        else
            bbwarn "do_deploy_network: DTB not found: $dtb"
        fi

        bbplain "==> [IMX93-DEPLOY] TFTP deploy complete."
    fi

    # =========================================================================
    # NFS rootfs deploy (via sudo nfs-extract.sh)
    # =========================================================================
    rootfs_tar="${deploy_dir}/${IMAGE_BASENAME}-${MACHINE}.rootfs.tar.zst"

    if [ ! -f "$nfs_script" ]; then
        bbwarn "do_deploy_network: NFS deploy skipped -- helper script not found: $nfs_script"
        bbwarn "  Run the one-time host setup described in imx93-deploy-network.bbclass comments."
    elif [ ! -f "$rootfs_tar" ]; then
        bbwarn "do_deploy_network: NFS deploy skipped -- rootfs tarball not found: $rootfs_tar"
    else
        bbplain "==> [IMX93-DEPLOY] Updating NFS rootfs at $nfs_dir (sudo)"
        sudo "$nfs_script" "$rootfs_tar" "$nfs_dir"
        bbplain "==> [IMX93-DEPLOY] NFS deploy complete."
    fi

    bbplain ""
    bbplain "==> [IMX93-DEPLOY] All done. Board can now:"
    bbplain "      run netflash   -- flash latest image to SD card over TFTP"
    bbplain "      run netboot    -- boot live from NFS root (no flashing)"
    bbplain ""
}

addtask do_deploy_network after do_image_complete before do_build
do_deploy_network[nostamp] = "1"
