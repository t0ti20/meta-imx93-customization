# Makefile for the NORMAL-WORLD (EL0) half of this demo -- the client
# application ("CA"). Unlike ../ta/Makefile, this one is completely
# ordinary: main.c is plain Linux userland C, so this is just a plain
# cross-compile-and-link rule, no special OP-TEE build system involved.
#
# CC/CFLAGS/LDFLAGS are NOT hardcoded here -- the recipe's do_compile()
# passes them in explicitly on the `make` command line:
#   oe_runmake -C ${S}/host \
#       CC="${CC}" \
#       CFLAGS="${CFLAGS} --sysroot=${STAGING_DIR_HOST}" \
#       LDFLAGS="${LDFLAGS} --sysroot=${STAGING_DIR_HOST}"
# The --sysroot flag is what makes `#include <tee_client_api.h>` and
# `-lteec` resolve at all: it points the cross-compiler/linker at Yocto's
# staged sysroot, where optee-client's headers/libs were installed because
# this recipe's DEPENDS includes "optee-client".

# `?=` (not `=`) means "only set this if it's not already set" -- lets
# this Makefile still do something sane (build with the host's own gcc)
# if you run `make` here by hand outside of bitbake, e.g. to sanity-check
# the C code compiles at all with a native compiler (it won't run TEEC_*
# calls successfully without a real /dev/tee0 + matching arch, but a
# native `make` here at least catches syntax errors quickly).
CC ?= gcc

# Name of the binary this produces, and what actually ends up installed at
# ${bindir}/imx93-hello-ca on the target rootfs (see the recipe's
# do_install()).
BINARY = imx93-hello-ca

.PHONY: all
all: $(BINARY)

# -I../ta/include: the ONLY reason the client needs to see anything under
#   ta/ at all -- imx93_hello_ta.h (the shared UUID + command-ID header)
#   physically lives there, purely by this project's own directory layout
#   choice. It is NOT a sign that the client links against the TA in any
#   way -- they remain two completely separate binaries, built by two
#   completely separate toolchains/build systems, running in two
#   completely separate worlds. Only the header's #define/struct-literal
#   TEXT is shared, copy-pasted at compile time into each side
#   independently.
# -lteec: link against libteec.so (from optee-client) for every TEEC_*
#   function used in main.c.
$(BINARY): main.c
	$(CC) $(CFLAGS) -I../ta/include -o $@ $< $(LDFLAGS) -lteec

.PHONY: clean
clean:
	rm -f $(BINARY)
