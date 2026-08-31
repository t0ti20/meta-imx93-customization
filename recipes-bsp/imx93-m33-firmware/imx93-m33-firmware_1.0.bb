SUMMARY = "i.MX93 CM33 pre-built firmware with udev auto-start"
DESCRIPTION = "Installs a pre-built Cortex-M33 ELF to /lib/firmware. A udev rule \
fires the moment the kernel creates remoteproc0 (during driver probe) and loads \
the firmware automatically — no service, no polling."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = ""

S = "${WORKDIR}"

inherit allarch

# ---------------------------------------------------------------------------
# Parse-time: read m33-config.json, validate the ELF.
# file-checksums on do_install invalidates sstate when the ELF changes.
# ---------------------------------------------------------------------------
python () {
    import json, os, struct

    cfg_file = os.path.join(d.getVar('THISDIR'), 'm33-config.json')
    if not os.path.isfile(cfg_file):
        bb.fatal("imx93-m33-firmware: config file not found: %s" % cfg_file)

    with open(cfg_file) as f:
        try:
            cfg = json.load(f)
        except ValueError as e:
            bb.fatal("imx93-m33-firmware: invalid JSON in %s: %s" % (cfg_file, e))

    elf = cfg.get('elf_path', '').strip()
    if not elf:
        bb.fatal("imx93-m33-firmware: 'elf_path' key missing or empty in %s" % cfg_file)

    if not os.path.isfile(elf):
        bb.fatal("imx93-m33-firmware: ELF not found: %s" % elf)

    with open(elf, 'rb') as f:
        header = f.read(20)

    if header[:4] != b'\x7fELF':
        bb.fatal("imx93-m33-firmware: not a valid ELF file (bad magic): %s" % elf)

    if header[4] != 1:
        bb.fatal("imx93-m33-firmware: ELF is not 32-bit (EI_CLASS=0x%x): %s" % (header[4], elf))

    if header[5] != 1:
        bb.fatal("imx93-m33-firmware: ELF is not little-endian (EI_DATA=0x%x): %s" % (header[5], elf))

    e_machine = struct.unpack_from('<H', header, 18)[0]
    if e_machine != 0x28:
        bb.fatal("imx93-m33-firmware: ELF is not ARM Cortex-M (e_machine=0x%x, expected 0x28): %s" % (e_machine, elf))

    install_name = cfg.get('install_name', 'imx93-m33.elf').strip()

    d.setVar('IMX93_M33_ELF_SRC', elf)
    d.setVar('IMX93_M33_ELF_NAME', install_name)

    d.setVarFlag('do_install', 'file-checksums', elf + ':True')

    bb.note("imx93-m33-firmware: ELF validated OK: %s" % elf)
}

do_configure[noexec] = "1"
do_compile[noexec] = "1"

do_install() {
    # ELF → /lib/firmware/
    install -d ${D}${nonarch_base_libdir}/firmware
    install -m 0644 ${IMX93_M33_ELF_SRC} \
        ${D}${nonarch_base_libdir}/firmware/${IMX93_M33_ELF_NAME}

    # udev helper: called by udev the moment remoteproc0 appears
    install -d ${D}${sbindir}
    printf '#!/bin/sh\n# Auto-generated: do not edit — change m33-config.json instead\nRPROC=/sys/class/remoteproc/remoteproc0\necho "%s" > "$RPROC/firmware"\necho start > "$RPROC/state"\n' \
        "${IMX93_M33_ELF_NAME}" > ${D}${sbindir}/imx93-m33-start
    chmod 0755 ${D}${sbindir}/imx93-m33-start

    # udev rule: fires on SUBSYSTEM=remoteproc, KERNEL=remoteproc0, ACTION=add
    install -d ${D}${sysconfdir}/udev/rules.d
    printf 'SUBSYSTEM=="remoteproc", KERNEL=="remoteproc0", ACTION=="add", RUN+="/usr/sbin/imx93-m33-start"\n' \
        > ${D}${sysconfdir}/udev/rules.d/99-imx93-m33.rules
}

FILES:${PN} = " \
    ${nonarch_base_libdir}/firmware/${IMX93_M33_ELF_NAME} \
    ${sbindir}/imx93-m33-start \
    ${sysconfdir}/udev/rules.d/99-imx93-m33.rules \
"

# Pre-built ARM binary — skip arch and strip QA checks
INSANE_SKIP:${PN} = "arch already-stripped"
