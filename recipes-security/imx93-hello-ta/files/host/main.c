/*
 * imx93-hello-ca -- the Normal-World half of this demo ("CA" = Client
 * Application, OP-TEE's own term for the EL0 process that talks to a TA).
 *
 * This is an entirely ordinary Linux userland program: it runs at EL0,
 * under the normal Linux kernel (EL1), with the normal C library -- it
 * could just as well be doing file I/O or opening a TCP socket. The ONLY
 * thing unusual about it is that it links against libteec (the OP-TEE
 * Client library, from the optee-client package this recipe DEPENDS/
 * RDEPENDS on) and uses that library's API to reach across the world
 * boundary.
 *
 * Every TEEC_* call below internally does an ioctl() on /dev/tee0 (the
 * "client doorway" device node from this repo's optee-trustzone-hands-on.md
 * lab 2 -- go check `ls -l /dev/tee*` on the board again if you haven't).
 * That ioctl() is a plain Linux syscall (an `svc` instruction under the
 * hood, from this EL0 process into the EL1 kernel) -- libteec hides that
 * detail from you entirely. What happens AFTER the ioctl(), inside the
 * kernel's TEE driver, is the `smc` -> BL31 -> OP-TEE -> TA chain described
 * in imx93_hello_ta.c's own comments and in the course's section 3.2.
 */
#include <err.h>
#include <stdio.h>
#include <string.h>

/*
 * tee_client_api.h is part of optee-client's -dev package: real headers,
 * installed to the normal ${includedir} like any other library (unlike
 * the TA side's tee_internal_api.h, which lives in a special TA-only
 * devkit) -- because this code runs as ordinary Linux userland, not
 * inside Secure World.
 */
#include <tee_client_api.h>

/* Shared with the TA side (files/ta/imx93_hello_ta.c) -- same UUID, same
 * command-ID contract. This is the only coupling between the two halves
 * of this demo; everything else about them is compiled completely
 * separately, by completely different build systems, for completely
 * different execution environments. */
#include <imx93_hello_ta.h>

int main(void)
{
	/* TEEC_Result: the return-code type for every OP-TEE Client API
	 * call -- TEEC_SUCCESS on success, various TEEC_ERROR_* on failure.
	 * Note this is TEEC_* (client side), a DIFFERENT type from the TA
	 * side's TEE_Result / TEE_SUCCESS despite the near-identical names
	 * -- easy to typo when switching between the two files. */
	TEEC_Result res;

	/* TEEC_Context: one per process, represents "this program's
	 * connection to the TEE subsystem as a whole" (roughly: the open
	 * file descriptor on /dev/tee0, wrapped up). Everything else below
	 * is created from, and must be torn down before, this context. */
	TEEC_Context ctx;

	/* TEEC_Session: one specific, stateful conversation with one
	 * specific TA (identified by UUID at open time, below). A process
	 * could open several sessions -- to the same TA, or to different
	 * TAs -- from one TEEC_Context. */
	TEEC_Session sess;

	/* TEEC_Operation: describes ONE invocation's worth of arguments --
	 * up to 4 typed "parameters" (values or shared-memory buffers) plus
	 * the "paramTypes" bitfield below that tells the TA how to
	 * interpret them. Re-used for both the open (unused here, we pass
	 * NULL at open time) and the actual invoke call further down. */
	TEEC_Operation op;

	/* TA_IMX93_HELLO_UUID expands to the brace-initializer from the
	 * shared header -- this line is where the client says WHICH secure
	 * application it wants to talk to. */
	TEEC_UUID uuid = TA_IMX93_HELLO_UUID;

	/* err_origin: an OUT parameter every OP-TEE Client API call fills
	 * in on failure, telling you WHICH layer rejected the call --
	 * TEEC_ORIGIN_API (this library, bad arguments), _COMMS (the
	 * kernel driver / transport), _TEE (OP-TEE core itself, S-EL1), or
	 * _TRUSTED_APP (the TA's own code, e.g. our TEE_ERROR_BAD_PARAMETERS
	 * from inc_value()). Extremely useful for telling "my CA is calling
	 * this wrong" apart from "my TA is misbehaving" while debugging. */
	uint32_t err_origin;

	/*
	 * Step 1: open a context. First argument is the TEE "name" -- NULL
	 * means "the default TEE", which on this board is the only one
	 * there is (OP-TEE, reached via the smc conduit the earlier dmesg
	 * probe found -- see optee-trustzone-hands-on.md lab 2). Internally
	 * this opens /dev/tee0.
	 */
	res = TEEC_InitializeContext(NULL, &ctx);
	if (res != TEEC_SUCCESS)
		errx(1, "TEEC_InitializeContext failed: 0x%x", res);

	/*
	 * Step 2: open a session against our TA's UUID. This is the call
	 * that actually triggers OP-TEE to locate imx93_hello_ta.c's
	 * compiled-and-signed .ta file (via tee-supplicant, since it's a
	 * REE FS TA) and run its TA_CreateEntryPoint() (if this is the
	 * first session ever) followed by TA_OpenSessionEntryPoint().
	 *
	 * TEEC_LOGIN_PUBLIC means "no particular client identity is being
	 * asserted" -- the simplest of several login methods OP-TEE
	 * supports (others let a TA see e.g. the calling process's Linux
	 * UID, for TAs that want to enforce per-user access).
	 *
	 * The two NULLs are: no TEEC_Operation for the open call itself
	 * (this demo has nothing to pass at open time, only at invoke
	 * time), and no "cancellation" sync object.
	 */
	res = TEEC_OpenSession(&ctx, &sess, &uuid, TEEC_LOGIN_PUBLIC,
				NULL, NULL, &err_origin);
	if (res != TEEC_SUCCESS)
		errx(1, "TEEC_OpenSession failed: 0x%x origin 0x%x",
		     res, err_origin);

	/* Zero the whole struct first -- TEEC_Operation has several fields
	 * we're not using (e.g. a cancellation flag), and leaving them as
	 * uninitialized stack garbage is asking for a confusing bug. */
	memset(&op, 0, sizeof(op));

	/*
	 * paramTypes must be built with TEEC_PARAM_TYPES(), the CLIENT-side
	 * mirror of the TA side's TEE_PARAM_TYPES() -- both sides must
	 * agree on this shape or the TA's own check (in inc_value()) will
	 * reject the call outright. TEEC_VALUE_INOUT here means "params[0]
	 * carries a 32-bit value both directions": we set params[0].value.a
	 * before the call as INPUT, and the TA overwrites the same field
	 * before returning, which we then read as OUTPUT. The other three
	 * slots are TEEC_NONE -- unused.
	 */
	op.paramTypes = TEEC_PARAM_TYPES(TEEC_VALUE_INOUT, TEEC_NONE,
					  TEEC_NONE, TEEC_NONE);

	/* The input value. Arbitrary choice -- 42 has no special meaning
	 * beyond being an easy number to recognize in the printf output
	 * below (expect to see 43 come back). */
	op.params[0].value.a = 42;

	printf("Invoking TA to increment %u\n", op.params[0].value.a);

	/*
	 * Step 3: the actual world-crossing call. THIS line is the one
	 * that does ioctl(/dev/tee0) -> svc -> Linux TEE driver (EL1) ->
	 * smc -> BL31 monitor (EL3, flips SCR.NS to 0) -> OP-TEE core
	 * (S-EL1) -> our TA's TA_InvokeCommandEntryPoint() (S-EL0) ->
	 * inc_value() -> and all the way back, synchronously -- this
	 * function does not return until the entire round trip, worlds and
	 * all, has completed.
	 *
	 * TA_IMX93_HELLO_CMD_INC_VALUE (from the shared header, value 0) is
	 * what arrives as the TA's cmd_id argument, telling it which
	 * `case` in its switch statement to run.
	 */
	res = TEEC_InvokeCommand(&sess, TA_IMX93_HELLO_CMD_INC_VALUE, &op,
				  &err_origin);
	if (res != TEEC_SUCCESS)
		errx(1, "TEEC_InvokeCommand failed: 0x%x origin 0x%x",
		     res, err_origin);

	/* op.params[0].value.a has now been overwritten by the TA -- this
	 * prints whatever the TA put there (expected: 43), read back on
	 * this side of the world boundary. The secret sauce (the "+1") ran
	 * entirely in Secure World; this process only ever saw the input
	 * and the output. */
	printf("TA incremented value to %u\n", op.params[0].value.a);

	/*
	 * Teardown, mirroring setup: close the session (runs the TA's
	 * TA_CloseSessionEntryPoint()) before finalizing the context
	 * (closes /dev/tee0). Getting this order backwards, or skipping
	 * it, leaks OP-TEE-side session state -- harmless for one quick
	 * demo run, but bad practice in anything long-lived.
	 */
	TEEC_CloseSession(&sess);
	TEEC_FinalizeContext(&ctx);
	return 0;
}
