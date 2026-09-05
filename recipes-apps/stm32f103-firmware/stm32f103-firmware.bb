SUMMARY = "STM32F103 target application firmware for fota-bootloader"
DESCRIPTION = "Ships the latest Test_*.bin built from the FOTA repo's \
Application/build/ into /lib/firmware/stm32f103/ so fota-bootloader has \
a target application image to flash on the STM32 on next reset. Latest \
is picked by filename (Test_YYYYMMDD_HHMMSS.bin sorts lexically as \
chronologically)."
HOMEPAGE = "https://github.com/t0ti20/FOTA/tree/master/Application"
SECTION = "firmware"

# Binary-only firmware artifact -- no source license file to hash. Bump
# and add LIC_FILES_CHKSUM if upstream ever publishes one.
LICENSE = "CLOSED"

# AUTOREV always pulls tip-of-branch. Pin SRCREV to a real commit for
# reproducible builds. Fetching only, no build -- just the .bin.
SRC_URI = "git://github.com/t0ti20/FOTA.git;protocol=https;branch=master"
SRCREV = "${AUTOREV}"
PV = "1.0+git${SRCPV}"

S = "${WORKDIR}/git"

# Data-only recipe -- nothing to configure/compile.
do_configure[noexec] = "1"
do_compile[noexec] = "1"

FIRMWARE_DIR = "${nonarch_base_libdir}/firmware/stm32f103"

do_install() {
    install -d ${D}${FIRMWARE_DIR}

    latest=$(find ${S}/Application/build -maxdepth 1 -type f \
                  -name 'Test_*.bin' 2>/dev/null | sort | tail -1)
    if [ -z "$latest" ]; then
        bbfatal "No Test_*.bin found in ${S}/Application/build/ -- \
did the repo layout change, or is this the wrong branch/repo?"
    fi

    bbnote "stm32f103-firmware: installing $(basename $latest)"
    install -m 0644 "$latest" ${D}${FIRMWARE_DIR}/
}

FILES:${PN} = "${FIRMWARE_DIR}"

# The firmware blob itself is arch-independent (it runs on the STM32, not
# the host), but leaving PACKAGE_ARCH at its default (machine) keeps the
# SPDX runtime lookup from fota-bootloader in the same architecture bucket
# -- an explicit "all" put the SPDX manifest under sstate:all-poky-linux/
# where the armv8a fota-bootloader's do_create_runtime_spdx wouldn't find it.
