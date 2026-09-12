# Companion to ../optee/optee-os_%.imx.bbappend -- REQUIRED, not optional,
# for TA-side IMSG()/DMSG()/etc. (e.g. imx93-hello-ta's) to ever produce
# output, no matter how high CFG_TEE_TA_LOG_LEVEL is set when building the
# TA itself.
#
# Why this second, separate bbappend is needed: optee-os_%.imx.bbappend
# only matches the recipe file "optee-os_4.2.0.imx.bb" (fnmatch on
# "optee-os_*.imx.bb") -- it does NOT match
# "optee-os-tadevkit_4.2.0.imx.bb" (extra "-tadevkit" breaks the match).
# optee-os and optee-os-tadevkit are two SEPARATE recipes that both
# `require optee-os-common-imx.inc` (which sets CFG_TEE_TA_LOG_LEVEL=0
# for both, by default) -- bumping the level on optee-os alone raises it
# for BL32/OP-TEE core, but optee-os-tadevkit is what actually BUILDS
# libutils.a, the library every out-of-tree TA (built via
# `-include $(TA_DEV_KIT_DIR)/mk/ta_dev_kit.mk`, e.g. imx93-hello-ta)
# links against.
#
# From optee_os's own mk/config.mk, verified in this exact BSP's fetched
# source (tmp/work/imx93frdm-poky-linux/optee-os/4.2.0.imx/git/mk/config.mk):
#
#   "If user-mode library libutils.a is built with CFG_TEE_TA_LOG_LEVEL=0,
#    TA tracing is disabled regardless of the value of CFG_TEE_TA_LOG_LEVEL
#    [used] when the TA is built."
#
# In other words: TA tracing capability is baked into libutils.a at THIS
# recipe's build time, not the consuming TA's. Skip this bbappend and a
# TA's own IMSG() calls compile to no-ops no matter what level the TA's
# own recipe/Makefile requests.
EXTRA_OEMAKE:append = " CFG_TEE_TA_LOG_LEVEL=3"
