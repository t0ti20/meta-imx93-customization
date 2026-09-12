/*
 * This header is #included by BOTH sides of the world boundary:
 *   - files/ta/imx93_hello_ta.c   -- runs in Secure World,  S-EL0 (the TA)
 *   - files/host/main.c           -- runs in Normal World,  EL0   (the CA)
 *
 * Neither side can see the other's memory or call the other's functions
 * directly -- the only thing they share is this *contract*: an identifying
 * UUID, and a set of small integer "command IDs". At runtime OP-TEE (S-EL1)
 * uses the UUID to find/load the right TA, and the TA's own
 * TA_InvokeCommandEntryPoint() switches on the command ID. That's the
 * entire API surface between the two worlds for this TA.
 */
#ifndef TA_IMX93_HELLO_H
#define TA_IMX93_HELLO_H

/*
 * Every OP-TEE Trusted Application is identified by a 128-bit UUID, not a
 * filename or a path. The Normal-world client (host/main.c) asks OP-TEE to
 * "open a session with UUID X"; OP-TEE looks that UUID up (built-in
 * pseudo-TA table, an early-TA data section, or -- for a REE FS TA like this
 * one -- a signed .ta file named exactly this UUID under
 * /lib/optee_armtz/) and loads/dispatches to it.
 *
 * This one was generated once with:
 *   python3 -c "import uuid; print(uuid.uuid4())"
 * -> bbbf5e6d-5ca1-4f1b-abb5-59876320a296
 *
 * The TEE_UUID / TEEC_UUID C struct (defined by the TA devkit / libteec
 * headers, not here) is NOT the same byte layout as the dashed string form.
 * A UUID string "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE" splits into the
 * struct like this:
 *   time_low                = 0xAAAAAAAA               (4 bytes)
 *   time_mid                = 0xBBBB                    (2 bytes)
 *   time_hi_and_version     = 0xCCCC                    (2 bytes)
 *   clock_seq_and_node[8]   = { 0xDD, 0xDD, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE }
 *                             (the DDDD group's 2 bytes, then the EEEE...
 *                              group's 6 bytes -- 8 bytes total)
 *
 * If you copy this file to make your OWN TA, generate a fresh UUID and
 * redo this split by hand (or use OP-TEE's own `scripts/uuid.py`) -- do not
 * reuse this exact value for a different TA, or OP-TEE will happily load
 * the wrong one.
 */
#define TA_IMX93_HELLO_UUID \
	{ 0xbbbf5e6d, 0x5ca1, 0x4f1b, \
		{ 0xab, 0xb5, 0x59, 0x87, 0x63, 0x20, 0xa2, 0x96 } }

/*
 * Command IDs are just plain integers, private to this TA -- OP-TEE itself
 * doesn't interpret them, it just hands whatever number the client passed
 * straight to TA_InvokeCommandEntryPoint()'s cmd_id argument. Different TAs
 * are free to reuse the same numbers for completely different meanings;
 * there's no global registry, because a client can only ever talk to the
 * one TA UUID it opened a session with.
 *
 * This TA implements exactly one command: take an integer in, add 1,
 * hand it back. That whole computation happens at S-EL0 -- deliberately
 * trivial, so the *plumbing* (the world crossing itself) is what you're
 * actually exercising, not the arithmetic.
 */
#define TA_IMX93_HELLO_CMD_INC_VALUE	0

#endif /* TA_IMX93_HELLO_H */
