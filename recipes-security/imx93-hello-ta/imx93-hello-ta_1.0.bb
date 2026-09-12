# imx93-hello-ta -- packages BOTH halves of the TrustZone/OP-TEE demo
# (files/ta/ = Secure World S-EL0, files/host/ = Normal World EL0) as one
# Yocto recipe, one package, so a single IMAGE_INSTALL entry ships both the
# .ta file and the CA binary together. See each source file's own
# comments for what the code actually does; this file is about how
# BITBAKE builds and packages it.
#
# The recipe is deliberately modeled on optee-test_4.2.0.imx.bb (the
# recipe that builds `xtest`, already in this image) -- same
# TA_DEV_KIT_DIR path, same DEPENDS-on-optee-os-tadevkit, same
# CROSS_COMPILE handling -- because that recipe is PROOF this exact
# pattern already works on this exact board (xtest runs successfully in
# lab 2 of Docs/optee-trustzone-hands-on.md).
#
# An earlier version of THIS recipe got that path wrong -- it copied an
# OLDER, unused meta-freescale optee-os recipe's convention
# (export-user_ta_${OPTEE_ARCH}, WITH an arch suffix, and DEPENDS on
# plain "optee-os") instead of checking what the actual optee-os_4.2.0.imx
# .bb (meta-imx-bsp, the one that wins) does. The failure mode was
# instructive: `-include $(TA_DEV_KIT_DIR)/mk/ta_dev_kit.mk` in
# ta/Makefile just silently found nothing (no build error), `make`
# fell through to the Makefile's only remaining rule ("clean"), and
# do_install() then failed on a missing *.ta with no earlier warning
# that the real cause was upstream. Lesson: when copying a "known good"
# recipe's convention, verify you're reading the recipe that actually
# wins dependency/version resolution for THIS build, not just any file
# with a plausible-looking name -- `bitbake -e <recipe> | grep ^DEPENDS`
# or checking the real tmp/work/.../temp/run.do_install would have caught
# this immediately.

SUMMARY = "Minimal OP-TEE Trusted Application + client demo for FRDM-IMX93"
DESCRIPTION = "TrustZone/OP-TEE hands-on demo: a TA that increments a value \
inside the secure world (S-EL0), invoked by a normal-world client via \
libteec. See Docs/optee-trustzone-hands-on.md in this layer."
LICENSE = "MIT"
# This project's own code (both TA and CA) is MIT-licensed -- this line
# just points at the standard MIT license text OpenEmbedded-core already
# ships, the same way this layer's hello-imx93/led-ctrl recipes do. It is
# NOT a statement about OP-TEE's own license (OP-TEE OS/client are
# BSD-2-Clause) -- LIC_FILES_CHKSUM only covers files THIS recipe provides.
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# Every file:// entry here is fetched from ./files/<same path>, because
# that's bitbake's DEFAULT search path for a recipe named
# imx93-hello-ta_1.0.bb sitting next to a files/ directory -- no
# FILESEXTRAPATHS override needed (this layer's other simple recipes,
# hello-imx93/led-ctrl, rely on the exact same default).
SRC_URI = " \
    file://ta/Makefile \
    file://ta/sub.mk \
    file://ta/include/imx93_hello_ta.h \
    file://ta/include/user_ta_header_defines.h \
    file://ta/imx93_hello_ta.c \
    file://host/Makefile \
    file://host/main.c \
"

# Normally S = "${WORKDIR}/<something>" points into an unpacked tarball or
# git checkout. Here there's no archive to unpack at all -- every file
# above is copied by bitbake's fetcher DIRECTLY into ${WORKDIR} at the
# relative path it was given (ta/Makefile lands at ${WORKDIR}/ta/Makefile,
# etc.), so ${WORKDIR} itself already has exactly the ta/ + host/ layout
# do_compile() below expects.
S = "${WORKDIR}"

# DEPENDS (build-time): need optee-client's headers/libs staged into the
# sysroot for host/main.c to compile+link against (tee_client_api.h,
# libteec.so). The TA devkit (ta_dev_kit.mk + TA-side headers/libutee,
# needed for ta/Makefile's `-include` to resolve to anything) comes from a
# SEPARATE recipe, optee-os-tadevkit -- NOT from optee-os itself. This
# BSP's actual optee-os_4.2.0.imx.bb (meta-imx-bsp) builds on top of
# meta-arm's generic optee-os.inc, which only packages firmware blobs +
# any TAs embedded in the OP-TEE OS source tree itself; the TA devkit for
# building YOUR OWN out-of-tree TAs is exported by optee-os-tadevkit_
# 4.2.0.imx.bb instead. Verified by checking what xtest's own recipe
# (optee-test_4.2.0.imx.bb -> optee-test-imx.inc -> meta-arm's
# optee-test.inc) actually DEPENDS on: "optee-client optee-os-tadevkit
# ...", not "optee-os" -- xtest is proof this pairing is what actually
# works on this board, the same way it was proof of the (as it turns out,
# WRONG) path this recipe used at first.
DEPENDS = "optee-client optee-os-tadevkit"

# RDEPENDS (runtime): the installed imx93-hello-ca binary is useless
# without libteec.so.1 actually present on the target rootfs at runtime
# to dynamically link against -- this line makes sure optee-client (which
# packages that .so) is pulled in automatically by any image that installs
# this recipe, without you having to remember to list it separately.
RDEPENDS:${PN} = "optee-client"

do_compile() {
    # Build the TA first. CROSS_COMPILE=${HOST_PREFIX} is the standard
    # Yocto cross-compiler prefix (e.g. aarch64-poky-linux-) that
    # ta_dev_kit.mk appends gcc/ld/objcopy/etc. onto internally.
    #
    # TA_DEV_KIT_DIR has NO arch suffix here -- this is
    # optee-os-tadevkit's own fixed install path
    # (${includedir}/optee/export-user_ta/, see that recipe's do_install),
    # not the arch-suffixed export-user_ta_arm64/ path an OLDER/unused
    # meta-freescale optee-os recipe would have produced. Get this wrong
    # (as an earlier version of this recipe did) and `-include` in
    # ta/Makefile silently finds nothing: `make` doesn't error, it just
    # falls through to the Makefile's only OTHER rule ("clean") and
    # produces no .ta at all -- do_install then fails with a confusing
    # "cannot stat '.../ta/*.ta'" instead of a clear "devkit not found".
    #
    # LIBGCC_LOCATE_CFLAGS: ta_dev_kit.mk's own link step locates libgcc.a
    # by running `$(CC) $(LIBGCC_LOCATE_CFLAGS) -print-libgcc-file-name`.
    # Leave this unset and that query runs with no arch flags at all,
    # which can make gcc report (or fail to report) a libgcc variant that
    # doesn't match how this TA is actually being compiled/linked --
    # exactly the "cannot find libgcc.a" linker error this build hit.
    # ${HOST_CC_ARCH}${TOOLCHAIN_OPTIONS} are the same two bitbake
    # variables meta-arm's optee.inc (the file xtest itself ultimately
    # builds through) passes for this exact reason -- copied here because
    # `oe_runmake -C ${S}/ta` calls make directly rather than through
    # EXTRA_OEMAKE, so it doesn't inherit that setting automatically the
    # way xtest's own bundled TAs do.
    oe_runmake -C ${S}/ta \
        CROSS_COMPILE=${HOST_PREFIX} \
        TA_DEV_KIT_DIR=${STAGING_INCDIR}/optee/export-user_ta \
        LIBGCC_LOCATE_CFLAGS="${HOST_CC_ARCH}${TOOLCHAIN_OPTIONS}"

    # Then build the CA. Unlike the TA side, this is just handing the
    # normal Yocto-computed CC/CFLAGS/LDFLAGS straight to a plain
    # Makefile -- see host/Makefile's own comments for exactly what each
    # of these buys you (mainly: --sysroot, so -lteec and
    # <tee_client_api.h> both resolve against the staged sysroot rather
    # than this build host's own, wrong, native libraries).
    oe_runmake -C ${S}/host \
        CC="${CC}" \
        CFLAGS="${CFLAGS} --sysroot=${STAGING_DIR_HOST}" \
        LDFLAGS="${LDFLAGS} --sysroot=${STAGING_DIR_HOST}"
}

do_install() {
    # The CA is an ordinary executable -- ${bindir} is /usr/bin on the
    # target, same place hello-imx93/led-ctrl install to.
    install -d ${D}${bindir}
    install -m 0755 ${S}/host/imx93-hello-ca ${D}${bindir}/

    # The TA is NOT an executable in the normal sense -- it's data, read
    # and verified by OP-TEE/tee-supplicant, never exec()'d by Linux.
    # ${nonarch_base_libdir}/optee_armtz (i.e. /lib/optee_armtz on this
    # machine) is OP-TEE's own fixed, hardcoded lookup directory for REE
    # FS TAs -- this is NOT a path you get to choose; put a .ta file
    # anywhere else and OP-TEE will simply never find it. 0444 (read-only,
    # no execute, no write) matches the permissions xtest's own test TAs
    # install with -- appropriate for a signed blob nothing should ever
    # need to modify in place.
    install -d ${D}${nonarch_base_libdir}/optee_armtz
    install -m 0444 ${S}/ta/*.ta ${D}${nonarch_base_libdir}/optee_armtz/
}

# FILES:${PN} tells bitbake's packaging step which of the files under ${D}
# belong to THIS package (as opposed to a QA warning about "files
# installed but not shipped in any package"). Both paths below are exactly
# what do_install() above just populated -- one package, containing both
# halves of the demo, so IMAGE_INSTALL only ever needs to name
# "imx93-hello-ta" once to get both the CA and the TA onto the rootfs
# together.
FILES:${PN} = " \
    ${bindir}/imx93-hello-ca \
    ${nonarch_base_libdir}/optee_armtz \
"
