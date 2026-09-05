SUMMARY = "FOTA Raspberry Pi host bootloader / OTA monitor"
DESCRIPTION = "Builds the Bootloader sub-application from the CPP_Application \
repository: the C++ host that talks to the STM32 target's UART bootloader, can \
flash a new application over it, and — run with '-r' — watches a GitHub repo for \
new firmware and flashes it automatically the next time the target resets. See \
Bootloader/README.md in the CPP_Application repository for full details."
HOMEPAGE = "https://github.com/t0ti20/CPP_Application"
SECTION = "examples"

# No LICENSE file is published for this code yet. Replace this (and add
# LIC_FILES_CHKSUM) once one exists.
LICENSE = "CLOSED"

DEPENDS = "boost"

SRC_URI = "git://github.com/t0ti20/CPP_Application.git;protocol=https;branch=master \
           file://fota-bootloader.service"

# Pin this to a real commit for reproducible builds, e.g.:
#   SRCREV = "43d3239..."
# AUTOREV always rebuilds against the current tip of the configured branch.
SRCREV = "${AUTOREV}"
PV = "1.0+git${SRCPV}"

# Build only the Bootloader sub-directory directly — its own CMakeLists.txt is
# a complete, standalone project, so there's no need to go through the
# repository's top-level CMakeLists.txt selector.
S = "${WORKDIR}/git/Bootloader"

inherit cmake systemd

# Bootloader/CMakeLists.txt already declares
# `install(TARGETS Bootloader DESTINATION bin)`, so the binary itself is
# installed automatically by cmake.bbclass's do_install. We only need to add
# the systemd unit on top of that.
do_install:append() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/fota-bootloader.service ${D}${systemd_system_unitdir}/fota-bootloader.service
    sed -i "s|@BINDIR@|${bindir}|g" ${D}${systemd_system_unitdir}/fota-bootloader.service
}

SYSTEMD_PACKAGES = "${PN}"
SYSTEMD_SERVICE:${PN} = "fota-bootloader.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

FILES:${PN} += "${systemd_system_unitdir}/fota-bootloader.service"
