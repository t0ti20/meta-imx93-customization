FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI:append = " file://0001-imx93-bl31-Add-IMX93-CUSTOM-boot-stage-banner.patch"

# Enable debug build: outputs to build/<plat>/debug/ instead of release/,
# and sets LOG_LEVEL=40 (INFO) so TF-A internal messages are also visible.
ATF_DEBUG = "1"
