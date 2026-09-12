# Top-level Makefile for the SECURE-WORLD (S-EL0) half of this demo.
#
# This is NOT a normal hand-rolled Makefile: it does almost nothing itself
# -- its only real job is `-include $(TA_DEV_KIT_DIR)/mk/ta_dev_kit.mk`
# below, which pulls in OP-TEE's own TA build system. That system reads
# sub.mk (in this same directory) to find out what to compile, then
# handles everything a TA build actually needs that a plain `$(CC) -o`
# could not:
#   - compiling against the TA devkit's own libutee/libutils, not glibc
#     (this is Secure-World S-EL0 code -- it can't use Normal-world
#     Linux's C library, because it isn't running under Linux at all)
#   - linking with the TA-specific linker script that lays the binary out
#     the way OP-TEE core expects to load it
#   - SIGNING the resulting binary into a .ta file (see this repo's
#     Docs/optee-trustzone-hands-on.md, "TA signing and the
#     default_ta.pem trap" -- this signing step is what makes this a REE
#     FS TA that OP-TEE will actually agree to load, and it's exactly
#     where that doc's warning about the default OP-TEE dev key applies)
#
# TA_DEV_KIT_DIR itself is NOT set here -- the recipe's do_compile() passes
# it in on the `make` command line:
#   TA_DEV_KIT_DIR=${STAGING_INCDIR}/optee/export-user_ta_${OPTEE_ARCH}
# i.e. wherever Yocto staged optee-os's TA devkit for this machine. Trying
# to `make` this directly outside of bitbake, without that variable set,
# will simply fail to find ta_dev_kit.mk.

# BINARY names the OUTPUT file this build produces: <BINARY>.ta, i.e. the
# signed Trusted Application OP-TEE will load. OP-TEE looks up REE FS TAs
# by UUID, so this MUST be your TA's UUID (dash-formatted, matching the
# TEE_UUID struct in include/imx93_hello_ta.h) -- not an arbitrary name.
BINARY = bbbf5e6d-5ca1-4f1b-abb5-59876320a296

# The "-include" (with the leading dash) means "include this if it exists,
# don't error out if it doesn't" -- useful so that e.g. `make clean` still
# works even before TA_DEV_KIT_DIR is known/valid. Once TA_DEV_KIT_DIR IS
# valid, this line is what defines the real `all`/install targets that
# actually build $(BINARY).ta -- everything after this line in a real
# OP-TEE TA Makefile is just extra hooks on top of what this pulls in.
-include $(TA_DEV_KIT_DIR)/mk/ta_dev_kit.mk

# sub-dirs-out / cleanfiles are variables ta_dev_kit.mk itself populates
# with every intermediate file it generated (object files, the unsigned
# ELF, etc.) -- this target just deletes all of them. Note the leading
# TAB before @$(RM) below is not optional: Make requires a literal tab
# character (not spaces) to introduce a recipe line, or it won't parse
# this as a rule at all.
clean:
	@$(RM) -f $(sub-dirs-out) $(cleanfiles)
