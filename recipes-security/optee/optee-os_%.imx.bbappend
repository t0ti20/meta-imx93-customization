# Turns UP the OP-TEE core/TA log level so `IMSG()` calls in Trusted
# Applications -- like imx93-hello-ta's -- actually print somewhere, for
# learning/debugging purposes. See
# ../imx93-hello-ta/README.md ("Verifying it's actually loaded and
# working" section) for the full context and why this is needed.
#
# Filename uses "_%.imx" (matching this BSP's own convention, e.g.
# meta-imx-sdk/recipes-security/stmm-imx/optee-os_%.imx.bbappend) rather
# than pinning the exact "_4.2.0.imx" version this recipe is at right now
# -- so this keeps applying automatically across a future optee-os
# version bump in this BSP, instead of silently stopping with no warning
# beyond bitbake's own "this .bbappend has no matching recipe" notice.
#
# CFG_TEE_CORE_LOG_LEVEL: 0=none 1=error 2=info 3=debug 4=flow
# CFG_TEE_TA_LOG_LEVEL:   same scale, gates TA-side IMSG()/DMSG()/EMSG()/etc.
#
# meta-imx/meta-imx-bsp/recipes-security/optee/optee-os-common-imx.inc
# (required by the real chain this recipe -- optee-os_4.2.0.imx.bb --
# actually goes through: optee-os_4.2.0.imx.bb -> optee-os-imx.inc ->
# optee-os-common-imx.inc) already sets BOTH of these to 0 via
# EXTRA_OEMAKE:append. A .bbappend is parsed AFTER the recipe/.inc chain
# it extends, so this second `:append` lands after that one in the final
# EXTRA_OEMAKE string; GNU Make takes the LAST value when the same
# variable is repeated on its command line, so these two values win.
#
# This changes BL32 itself (firmware baked into imx-boot), NOT the
# rootfs -- rebuilding this recipe alone changes nothing on a
# already-flashed board. You must also rebuild u-boot-imx (which repacks
# imx-boot with the new BL32) and RE-FLASH the bootloader -- see this
# layer's top-level README, "--flash-boot" section, for exactly how.
EXTRA_OEMAKE:append = " CFG_TEE_CORE_LOG_LEVEL=2 CFG_TEE_TA_LOG_LEVEL=3"
