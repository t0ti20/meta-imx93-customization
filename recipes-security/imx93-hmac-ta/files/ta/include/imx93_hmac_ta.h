/*
 * Shared contract between the TA (files/ta/imx93_hmac_ta.c, S-EL0) and the
 * CA (files/host/main.cpp, EL0). Same pattern as imx93-hello-ta's header --
 * see that recipe's comments for the general UUID/command-ID explanation
 * if this is your first TA in this layer.
 */
#ifndef TA_IMX93_HMAC_H
#define TA_IMX93_HMAC_H

/* Generated with: python3 -c "import uuid; print(uuid.uuid4())"
 * -> 88344489-54f5-429e-9a70-be08fe7c81cf
 * Fork this TA for something else? Generate your own and redo this split. */
#define TA_IMX93_HMAC_UUID \
	{ 0x88344489, 0x54f5, 0x429e, \
		{ 0x9a, 0x70, 0xbe, 0x08, 0xfe, 0x7c, 0x81, 0xcf } }

/*
 * The three commands this TA implements -- deliberately mirroring OP-TEE's
 * own streaming MAC API one-to-one (TEE_MACInit / TEE_MACUpdate /
 * TEE_MACComputeFinal), so the CA can HMAC a file of ANY size without ever
 * holding the whole file in Secure World memory at once: read a chunk on
 * the Normal-world side, append it, repeat, then finalize.
 */

/* Reset the streaming HMAC operation and start a fresh message. Call this
 * before HMAC-ing a new file/stream -- it does NOT touch the key (the key
 * is generated/loaded once per TA instance, not per stream). No params. */
#define TA_HMAC_CMD_CLEAR		0

/* Feed one chunk of data into the ongoing HMAC computation. Can be called
 * any number of times in a row -- HMAC-SHA256 is a true streaming
 * algorithm, so 1 call with the whole buffer and 1000 calls with 1 byte
 * each produce an IDENTICAL result. params[0] = memref IN (the chunk). */
#define TA_HMAC_CMD_APPEND_DATA		1

/* Return the HMAC-SHA256 digest of everything appended SO FAR, as a
 * non-destructive CHECKPOINT -- the running stream is left untouched, so
 * you can keep calling APPEND_DATA afterward and it continues the exact
 * same message. Calling this again later returns the HMAC over
 * everything appended cumulatively (old + new), not just the new part.
 * Only CLEAR actually discards the running stream and starts over.
 * params[0] = memref OUT (caller-allocated buffer, >= 32 bytes; the TA
 * writes the actual digest size back into the memref's .size field). */
#define TA_HMAC_CMD_GET_FINAL		2

/* HMAC-SHA256 always produces exactly 32 bytes -- the CA uses this to
 * size its output buffer, rather than hardcoding "32" in two places. */
#define TA_HMAC_DIGEST_SIZE		32

#endif /* TA_IMX93_HMAC_H */
