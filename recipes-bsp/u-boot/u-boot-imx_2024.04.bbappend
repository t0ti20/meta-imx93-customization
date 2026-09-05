FILESEXTRAPATHS:prepend := "${THISDIR}/${BPN}:"

# FRDM-IMX93 REV B2 boards ship with a substituted 2CS/2GB LPDDR4X part
# (JSC JSL4BAG167ZAMF) instead of the schematic's original Micron
# MT53E1G16D1FW (1CS). Without this patch DDR training never validates
# on affected boards and SPL hangs right after "M33 prepare ok".
# Must apply after meta-imx-frdm's 0002-imx-imx93_frdm-Add-basic-board-support.patch
# (which creates board/freescale/imx93_frdm/ in the first place); layer
# priority (20 > 8) guarantees that ordering.
SRC_URI += " \
    file://0010-imx93_frdm-Add-2CS-2GB-DRAM-support.patch \
    file://0020-imx93_frdm-Add-network-image-flash.patch \
    file://0030-imx93_frdm-Add-network-first-boot-with-static-IP.patch \
    file://0040-imx93_frdm-spl-Add-IMX93-CUSTOM-boot-stage-banner.patch \
"

# ---- Optional feature: LPUART5/6 header mode on connector P11 ----
# Single toggle lives in recipes-fsl/images/imx93-features.inc; both the
# image recipe and this bbappend `require` it so the same value applies
# during their (independent) parses.
require recipes-fsl/images/imx93-features.inc
SRC_URI += "${@' file://imx93_frdm_lpuart_header.cfg file://0035-imx93_frdm-netflash-use-fdtfile-for-lpuart-mode.patch' if d.getVar('IMX93_UART_HEADER_MODE') == '1' else ''}"
