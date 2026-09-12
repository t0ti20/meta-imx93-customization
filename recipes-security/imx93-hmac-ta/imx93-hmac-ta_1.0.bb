# imx93-hmac-ta -- streaming HMAC-SHA256 Trusted Application + colorful
# CLI client for FRDM-IMX93. See files/ta/imx93_hmac_ta.c and
# files/host/main.cpp for what the code does; see README.md for how to
# build/test/verify it. This recipe follows the exact same TA_DEV_KIT_DIR/
# DEPENDS/LIBGCC_LOCATE_CFLAGS pattern imx93-hello-ta already established
# and verified working on this board -- see that recipe's own comments
# and README.md "Troubleshooting" section for the full story of why this
# specific combination is required on this exact BSP (not the path a
# naive read of an older, unused meta-freescale optee-os recipe would
# suggest).

SUMMARY = "Streaming HMAC-SHA256 OP-TEE Trusted Application + CLI client for FRDM-IMX93"
DESCRIPTION = "TrustZone/OP-TEE demo: a TA computing HMAC-SHA256 entirely \
inside the secure world (S-EL0) via a 3-command streaming API (Clear / \
Append_Data / Get_Final), with a colorful menu-driven Normal-World client \
that can HMAC an arbitrary file. Uses a secure-storage-backed key when \
available, falling back to an embedded testing-only key otherwise. See \
Docs/optee-trustzone-hands-on.md in this layer for the underlying \
TrustZone concepts, and recipes-security/imx93-hello-ta for the simpler, \
heavily-commented sibling demo this one builds on."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://ta/Makefile \
    file://ta/sub.mk \
    file://ta/include/imx93_hmac_ta.h \
    file://ta/include/user_ta_header_defines.h \
    file://ta/imx93_hmac_ta.c \
    file://host/Makefile \
    file://host/main.cpp \
"

S = "${WORKDIR}"

# optee-os-tadevkit: the TA build system + TA-side headers/libutils.a this
# TA links against (NOT plain "optee-os" -- see imx93-hello-ta's own
# comments/README for exactly why that distinction matters on this BSP).
# optee-client: libteec + tee_client_api.h for the host/ CLI.
DEPENDS = "optee-client optee-os-tadevkit"
RDEPENDS:${PN} = "optee-client"

do_compile() {
    # TA build. LIBGCC_LOCATE_CFLAGS is REQUIRED here -- without it,
    # ta_dev_kit.mk's link step can fail to locate libgcc.a entirely (see
    # imx93-hello-ta/README.md's Troubleshooting section for the exact
    # error this omission produces and why ${HOST_CC_ARCH}${TOOLCHAIN_OPTIONS}
    # fixes it).
    oe_runmake -C ${S}/ta \
        CROSS_COMPILE=${HOST_PREFIX} \
        TA_DEV_KIT_DIR=${STAGING_INCDIR}/optee/export-user_ta \
        LIBGCC_LOCATE_CFLAGS="${HOST_CC_ARCH}${TOOLCHAIN_OPTIONS}"

    # CLI client build (C++, unlike imx93-hello-ca's plain C -- CXX/CXXFLAGS
    # here, not CC/CFLAGS).
    oe_runmake -C ${S}/host \
        CXX="${CXX}" \
        CXXFLAGS="${CXXFLAGS} --sysroot=${STAGING_DIR_HOST}" \
        LDFLAGS="${LDFLAGS} --sysroot=${STAGING_DIR_HOST}"
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${S}/host/imx93-hmac-ca ${D}${bindir}/

    install -d ${D}${nonarch_base_libdir}/optee_armtz
    install -m 0444 ${S}/ta/*.ta ${D}${nonarch_base_libdir}/optee_armtz/
}

FILES:${PN} = " \
    ${bindir}/imx93-hmac-ca \
    ${nonarch_base_libdir}/optee_armtz \
"
