SUMMARY = "RGB LED color controller for i.MX93 FRDM"
DESCRIPTION = "Daemon that fades through all colors on the board's RGB LED. \
When called with a hex color argument it stops fading and holds that color. \
Controls the LED via the PWM sysfs interface."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://led-ctrl.cpp \
    file://led-ctrl.service \
"

S = "${WORKDIR}"

inherit systemd

SYSTEMD_SERVICE:${PN} = "led-ctrl.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_configure[noexec] = "1"

do_compile() {
    ${CXX} ${CXXFLAGS} ${LDFLAGS} -O2 -std=c++11 \
        -o led-ctrl led-ctrl.cpp -lm
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 led-ctrl ${D}${bindir}/led-ctrl

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 led-ctrl.service \
        ${D}${systemd_system_unitdir}/led-ctrl.service
}

FILES:${PN} = " \
    ${bindir}/led-ctrl \
    ${systemd_system_unitdir}/led-ctrl.service \
"
