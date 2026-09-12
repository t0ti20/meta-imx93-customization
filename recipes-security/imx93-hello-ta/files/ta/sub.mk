# sub.mk -- read by OP-TEE's own TA build system (ta_dev_kit.mk, pulled in
# by ./Makefile). This is NOT a standalone Makefile you'd run directly --
# ta_dev_kit.mk `include`s this file to learn what to build, then does all
# the actual compiling/linking/signing itself using rules internal to the
# OP-TEE OS source tree (which is why building a TA needs the TA devkit at
# all, rather than just calling $(CC) by hand like the host/ CA does).

# Add ./include to this TA's own header search path, so
# imx93_hello_ta.c's `#include <imx93_hello_ta.h>` (angle brackets, not
# quotes) resolves to ./include/imx93_hello_ta.h.
global-incdirs-y += include

# The actual source file(s) making up this TA. Just the one file here --
# add more `srcs-y +=` lines if the TA grows.
srcs-y += imx93_hello_ta.c
