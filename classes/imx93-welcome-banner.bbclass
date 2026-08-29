# Writes a pretty, build-stamped welcome banner to /etc/issue and /etc/motd
# in the rootfs -- same "****...****" banner style used by this layer's
# U-Boot boot/flash logging (see recipes-bsp/u-boot/u-boot-imx/*.patch), so
# a build's identity (image, machine, distro, when, by whom) is visible the
# moment the serial console reaches the login prompt, without needing to
# `cat /etc/os-release` or dig through /etc/build-id first.
#
# Usage: inherit this class from an image recipe. IMX93_BUILDER can be
# overridden per build (e.g. in local.conf) if someone other than the
# default builder produces a given image.

IMX93_BUILD_TIMESTAMP := "${@time.strftime('%Y-%m-%d %H:%M:%S', time.localtime())}"
IMX93_BUILDER ?= "Khaled El-Sayed"

ROOTFS_POSTPROCESS_COMMAND += "imx93_write_welcome_banner; "

imx93_write_welcome_banner () {
	banner="${IMAGE_ROOTFS}${sysconfdir}/issue"
	cat > "$banner" <<EOF
********************************************************
*  [IMX93-CUSTOM] NXP i.MX93 FRDM Security Testing Image
********************************************************
*  Image      : ${PN}
*  Machine    : ${MACHINE}
*  Distro     : ${DISTRO} ${DISTRO_VERSION}
*  Built      : ${IMX93_BUILD_TIMESTAMP}
*  Builder    : ${IMX93_BUILDER}
********************************************************

\n \l

EOF
	cp "$banner" "${IMAGE_ROOTFS}${sysconfdir}/motd"
}
