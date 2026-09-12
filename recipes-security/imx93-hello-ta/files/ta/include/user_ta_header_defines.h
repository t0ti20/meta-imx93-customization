/*
 * user_ta_header_defines.h -- MANDATORY for every OP-TEE Trusted
 * Application, not optional boilerplate. ta_dev_kit.mk (pulled in by
 * ../Makefile) unconditionally compiles a file called user_ta_header.c
 * (from inside the TA devkit itself, NOT from this project) which does
 * `#include <user_ta_header_defines.h>` -- that's the file you're reading
 * right now, found via sub.mk's `global-incdirs-y += include`. Without
 * it, the build fails exactly the way it just did: "fatal error:
 * user_ta_header_defines.h: No such file or directory", because
 * ta_dev_kit.mk has no idea what UUID/stack size/etc. to bake into this
 * TA's header without it.
 *
 * Everything in this file becomes part of the TA's *header* -- metadata
 * OP-TEE core reads BEFORE running a single line of imx93_hello_ta.c, to
 * decide things like how much stack/heap to give this TA and which UUID
 * to register it under.
 */
#ifndef USER_TA_HEADER_DEFINES_H
#define USER_TA_HEADER_DEFINES_H

/* Reuse the same UUID macro the TA implementation and the CA both use --
 * defined once in imx93_hello_ta.h, so there is exactly one place that
 * ever needs updating if you fork this into a TA with its own identity. */
#include <imx93_hello_ta.h>

/* TA_UUID is the specific macro name ta_dev_kit.mk's user_ta_header.c
 * looks for -- this is NOT the same identifier as TA_IMX93_HELLO_UUID
 * itself, it's OP-TEE's own required name, just pointed at our value. */
#define TA_UUID TA_IMX93_HELLO_UUID

/*
 * TA_FLAGS: behavioral flags OP-TEE core applies when loading this TA.
 * TA_FLAG_EXEC_DDR -- run the TA's code out of DDR (normal for a
 * usermode/REE-FS TA like this one; the alternative, running out of
 * on-chip SRAM, is for TAs with much stricter physical-attack threat
 * models than a learning demo needs).
 * TA_FLAG_SINGLE_INSTANCE -- OP-TEE keeps exactly ONE instance of this TA
 * loaded, shared across every session any client opens against it,
 * instead of a fresh instance per session. TA_CreateEntryPoint() in
 * imx93_hello_ta.c only runs once, ever, per boot, as a direct result of
 * this flag -- open a second session from a second terminal on the board
 * and you'll see "session opened" print again, but NOT TA_CreateEntryPoint's
 * effects re-running.
 * TA_FLAG_MULTI_SESSION -- explicitly allow more than one concurrent
 * session (the combination with SINGLE_INSTANCE above is the standard,
 * safe default for a stateless demo TA like this one; omitting it would
 * make OP-TEE refuse a second simultaneous client).
 */
#define TA_FLAGS (TA_FLAG_EXEC_DDR | TA_FLAG_SINGLE_INSTANCE | TA_FLAG_MULTI_SESSION)

/* TA_STACK_SIZE: this TA's own S-EL0 stack, carved out of Secure World
 * memory at load time. 2 KiB is generous for a function that does one
 * addition -- real TAs doing crypto or parsing untrusted input need to
 * size this deliberately and audit against overflow (this exact class of
 * bug is one of the "Issues and Limitations" real CVEs cited in the
 * TrustZone concept doc -- an S-EL0 stack buffer overflow in a
 * commercial TEE). */
#define TA_STACK_SIZE (2 * 1024)

/* TA_DATA_SIZE: heap available to this TA (malloc() inside TA code draws
 * from this pool, not from Linux's memory). 32 KiB is far more than this
 * demo needs -- it does no dynamic allocation at all -- but is a
 * conservative, common default for a small TA. */
#define TA_DATA_SIZE (32 * 1024)

/*
 * TA_CURRENT_TA_EXT_PROPERTIES: optional GlobalPlatform-standard
 * key/value metadata about this TA, queryable by the CA (or tooling) via
 * TEEC_InvokeCommand's property APIs -- purely descriptive, doesn't
 * affect how the TA runs. Included here mainly so you have a template to
 * extend if you add more properties to a TA you build from this one.
 */
#define TA_CURRENT_TA_EXT_PROPERTIES \
	{ "gp.ta.description", USER_TA_PROP_TYPE_STRING, \
		"imx93-hello-ta: increments a value inside the secure world" }, \
	{ "gp.ta.version", USER_TA_PROP_TYPE_U32, &(const uint32_t){ 0x0100 } }

#endif /* USER_TA_HEADER_DEFINES_H */
