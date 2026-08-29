# Auto-deploys freshly built IMX93 FRDM artifacts to the host's TFTP server
# after every successful do_image_complete, and purges stale Raspberry Pi
# artifacts from the TFTP root (RPi4 netboot is no longer served from this
# server -- all RPi files at the top level of TFTP_DIR are removed).
#
# TFTP layout produced by this task:
#   $IMX93_TFTP_DIR/
#     imx-image-sec-*-imx93frdm.rootfs.wic.gz   (fetched by: run netflash)
#     imx93/
#       Image                                     (fetched by: run netboot)
#       imx93-11x11-frdm.dtb
#
# NFS rootfs deploy still requires sudo and is NOT done here -- run
# scripts/deploy-to-network.sh --nfs-only after bitbake completes.
#
# Override IMX93_TFTP_DIR in local.conf if your TFTP root differs from the
# default below.

IMX93_TFTP_DIR ?= "/home/khaled/Documents/Network/TFTP"

do_deploy_network() {
    tftp_dir="${IMX93_TFTP_DIR}"
    deploy_dir="${DEPLOY_DIR_IMAGE}"

    if [ ! -d "$tftp_dir" ]; then
        bbwarn "do_deploy_network: IMX93_TFTP_DIR=$tftp_dir does not exist -- skipping TFTP deploy"
        return
    fi

    # --- purge stale RPi4 artifacts from TFTP root ---------------------------
    # The root-level Image was the RPi4 kernel; imx93 kernel lives under imx93/
    bbplain "==> [IMX93-DEPLOY] Purging stale RPi4 artifacts from $tftp_dir/"
    if [ -f "$tftp_dir/Image" ]; then
        bbplain "    rm $tftp_dir/Image  (RPi4 kernel -- imx93 kernel is at imx93/Image)"
        rm -f "$tftp_dir/Image"
    fi
    for f in "$tftp_dir"/bcm2711-*.dtb \
              "$tftp_dir"/*.dtbo \
              "$tftp_dir"/overlay_map.dtb; do
        [ -f "$f" ] && { bbplain "    rm $(basename $f)"; rm -f "$f"; }
    done

    # --- deploy WIC.gz (for: run netflash) -----------------------------------
    wic_gz="${deploy_dir}/${IMAGE_BASENAME}-${MACHINE}.rootfs.wic.gz"
    if [ -f "$wic_gz" ]; then
        bbplain "==> [IMX93-DEPLOY] $(basename $wic_gz) -> $tftp_dir/"
        install -m 0644 "$wic_gz" "$tftp_dir/"
    else
        bbwarn "do_deploy_network: WIC.gz not found -- build ${IMAGE_BASENAME} with IMAGE_FSTYPES += wic.gz: $wic_gz"
    fi

    # --- deploy kernel + dtb (for: run netboot) ------------------------------
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

    bbplain ""
    bbplain "==> [IMX93-DEPLOY] TFTP deploy complete."
    bbplain "    NFS rootfs update (requires sudo):"
    bbplain "      scripts/deploy-to-network.sh --nfs-only"
    bbplain ""
}

addtask do_deploy_network after do_image_complete before do_build
do_deploy_network[nostamp] = "1"
