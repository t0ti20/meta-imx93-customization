SUMMARY = "Hello World demo application for NXP i.MX93 FRDM"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://main.cpp \
           file://hello-imx93.hpp"

S = "${WORKDIR}"

do_compile() {
    ${CXX} ${CXXFLAGS} ${LDFLAGS} -std=c++17 -o hello-imx93 main.cpp
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 hello-imx93 ${D}${bindir}/
}
