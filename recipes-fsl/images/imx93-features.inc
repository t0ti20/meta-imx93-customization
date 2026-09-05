# Shared feature-toggle file for meta-imx93-customization.
#
# Both imx-image-sec-min.bb and recipes-bsp/u-boot/u-boot-imx_2024.04.bbappend
# `require` this file so the toggles below are visible in both parses (bitbake
# parses each recipe in an isolated datastore, so a variable set only inside
# an image recipe would not reach u-boot). Change the value in ONE place -- at
# the top of imx-image-sec-min.bb -- and it takes effect for both.
#
# IMX93_UART_HEADER_MODE
#   "0" (default) -- stock imx93-11x11-frdm.dtb; Bluetooth on LPUART5 as
#                    shipped by NXP.
#   "1"           -- boot imx93-11x11-frdm-lpuart.dtb by default (from
#                    meta-imx-frdm's kernel patch 0013): deletes the BT HCI
#                    child on &lpuart5 and enables &lpuart6, exposing
#                        /dev/ttyLP4 -- LPUART5 -- P11 pin 27=TX pin 28=RX
#                        /dev/ttyLP5 -- LPUART6 -- P11 pin  7=TX pin 29=RX
#                    Trade-off: on-board Bluetooth stops working (WiFi is
#                    unaffected -- it's SDIO). Pads are 1.8 V; use a level
#                    shifter for 3.3 V/5 V targets.
#
#                    After flashing onto a board whose U-Boot env was
#                    previously saved, run `env default -a; saveenv` at the
#                    U-Boot prompt once to drop any saved fdtfile that would
#                    otherwise override the new compiled-in default.
# EDIT THIS LINE to toggle the LPUART header feature.
IMX93_UART_HEADER_MODE = "0"
