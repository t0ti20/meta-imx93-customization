/*
 * imx93-hmac-ta -- streaming HMAC-SHA256 computed entirely inside Secure
 * World (S-EL0). Implements exactly the three commands this feature
 * asked for, mapped one-to-one onto OP-TEE's own streaming MAC API:
 *
 *   HMAC_Clear       -> TEE_MACInit()          (start a fresh message)
 *   HMAC_Append_Data -> TEE_MACUpdate()        (feed in one chunk)
 *   HMAC_Get_Final   -> TEE_MACComputeFinal()  (finish, return the digest)
 *
 * See imx93-hello-ta's own .c file for the general entry-point/world-
 * crossing explanation if this is your first TA in this layer -- this
 * file assumes that context and focuses on what's new here: real crypto,
 * persistent per-session state, and key management.
 */
#include <tee_internal_api.h>
#include <tee_internal_api_extensions.h>
#include <string.h>
#include <imx93_hmac_ta.h>

#define HMAC_KEY_BITS 256

/* Persistent-object ID for this TA's own secure-storage partition
 * (TEE_STORAGE_PRIVATE) -- arbitrary bytes, but must stay STABLE across
 * boots/rebuilds so the same key is found again next time, rather than
 * silently generating a new one every reboot (which would make an HMAC
 * computed yesterday disagree with today's for no obvious reason). */
static const char HMAC_KEY_OBJECT_ID[] = "imx93-hmac-ta.key.v1";

/*
 * FALLBACK ONLY, for a board/config where secure storage isn't usable at
 * all. Anyone who can read this file (or the shipped, merely-SIGNED-not-
 * ENCRYPTED optee_armtz/*.ta on the rootfs) can trivially recover this
 * exact key -- it provides zero confidentiality. It exists purely so this
 * TA still WORKS for testing on a board without working secure storage,
 * per this feature's own "generate a dummy key, no problem, for testing"
 * requirement. Replace before using this TA for anything where the HMAC
 * needs to resist an attacker who has the firmware image.
 */
static const uint8_t HMAC_DUMMY_KEY[HMAC_KEY_BITS / 8] = {
	0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
	0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
	0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE,
	0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF,
};

/* Per-SESSION state -- lets two different clients each stream their own
 * independent HMAC without interfering, even though they share the one
 * loaded TA instance and the one underlying key. */
struct hmac_session_ctx {
	TEE_OperationHandle mac_op;
	bool key_is_hw_backed; /* true = secure-storage key, false = dummy */
};

/*
 * get_hmac_key() -- the "internal hw key if it exists, else dummy key"
 * logic, implemented with real GlobalPlatform TEE Internal API calls:
 *
 *   1. Try to OPEN an existing persistent key object. Persistent objects
 *      in TEE_STORAGE_PRIVATE are encrypted at rest by OP-TEE's secure
 *      storage subsystem, whose own protection key ultimately derives
 *      from this SoC's Hardware Unique Key (HUK). A TA can never read the
 *      HUK directly -- GlobalPlatform deliberately doesn't expose it --
 *      but it CAN get a key whose confidentiality-at-rest depends on it.
 *      That's what "internal hw key" means in practice from inside a TA;
 *      there is no TEE_TYPE_HUK a TA can just grab.
 *   2. If none exists yet (TEE_ERROR_ITEM_NOT_FOUND, e.g. first boot),
 *      GENERATE a real random 256-bit key and persist it, so every future
 *      call -- even after a reboot -- finds and reuses the SAME key.
 *   3. If persistent storage itself is unusable on this board/build (any
 *      other error), fall back to the embedded HMAC_DUMMY_KEY.
 */
static TEE_Result get_hmac_key(TEE_ObjectHandle *key_handle, bool *hw_backed)
{
	TEE_Result res;
	TEE_ObjectHandle transient_key = TEE_HANDLE_NULL;
	TEE_Attribute attr;

	res = TEE_OpenPersistentObject(TEE_STORAGE_PRIVATE,
					HMAC_KEY_OBJECT_ID,
					sizeof(HMAC_KEY_OBJECT_ID),
					TEE_DATA_FLAG_ACCESS_READ |
					TEE_DATA_FLAG_SHARE_READ,
					key_handle);
	if (res == TEE_SUCCESS) {
		IMSG("imx93-hmac-ta: reusing existing secure-storage-backed key");
		*hw_backed = true;
		return TEE_SUCCESS;
	}

	if (res != TEE_ERROR_ITEM_NOT_FOUND) {
		EMSG("imx93-hmac-ta: TEE_OpenPersistentObject failed: 0x%x -- "
		     "secure storage looks unavailable on this build", res);
		goto fallback;
	}

	IMSG("imx93-hmac-ta: no stored key yet -- generating one");

	res = TEE_AllocateTransientObject(TEE_TYPE_HMAC_SHA256, HMAC_KEY_BITS,
					   &transient_key);
	if (res != TEE_SUCCESS) {
		EMSG("imx93-hmac-ta: TEE_AllocateTransientObject failed: 0x%x", res);
		goto fallback;
	}

	res = TEE_GenerateKey(transient_key, HMAC_KEY_BITS, NULL, 0);
	if (res != TEE_SUCCESS) {
		EMSG("imx93-hmac-ta: TEE_GenerateKey failed: 0x%x", res);
		TEE_FreeTransientObject(transient_key);
		goto fallback;
	}

	res = TEE_CreatePersistentObject(TEE_STORAGE_PRIVATE,
					  HMAC_KEY_OBJECT_ID,
					  sizeof(HMAC_KEY_OBJECT_ID),
					  TEE_DATA_FLAG_ACCESS_READ |
					  TEE_DATA_FLAG_ACCESS_WRITE_META |
					  TEE_DATA_FLAG_SHARE_READ,
					  transient_key, NULL, 0,
					  key_handle);
	/* TEE_CreatePersistentObject COPIES the key material out of
	 * transient_key -- our handle to it stays independently valid
	 * either way, so it must be freed here regardless of outcome. */
	TEE_FreeTransientObject(transient_key);

	if (res == TEE_SUCCESS) {
		IMSG("imx93-hmac-ta: generated + persisted a new secure-storage-backed key");
		*hw_backed = true;
		return TEE_SUCCESS;
	}
	EMSG("imx93-hmac-ta: TEE_CreatePersistentObject failed: 0x%x", res);

fallback:
	IMSG("imx93-hmac-ta: WARNING -- falling back to the embedded dummy "
	     "key (testing only, NOT secret -- see this file's own comment)");

	res = TEE_AllocateTransientObject(TEE_TYPE_HMAC_SHA256, HMAC_KEY_BITS,
					   key_handle);
	if (res != TEE_SUCCESS) {
		EMSG("imx93-hmac-ta: fallback TEE_AllocateTransientObject failed: 0x%x", res);
		return res;
	}

	TEE_InitRefAttribute(&attr, TEE_ATTR_SECRET_VALUE,
			      HMAC_DUMMY_KEY, sizeof(HMAC_DUMMY_KEY));
	res = TEE_PopulateTransientObject(*key_handle, &attr, 1);
	if (res != TEE_SUCCESS) {
		EMSG("imx93-hmac-ta: TEE_PopulateTransientObject failed: 0x%x", res);
		TEE_FreeTransientObject(*key_handle);
		return res;
	}

	*hw_backed = false;
	return TEE_SUCCESS;
}

TEE_Result TA_CreateEntryPoint(void)
{
	return TEE_SUCCESS;
}

void TA_DestroyEntryPoint(void)
{
}

TEE_Result TA_OpenSessionEntryPoint(uint32_t param_types __unused,
				     TEE_Param params[4] __unused,
				     void **sess_ctx)
{
	TEE_Result res;
	TEE_ObjectHandle key_handle = TEE_HANDLE_NULL;
	struct hmac_session_ctx *ctx;

	ctx = TEE_Malloc(sizeof(*ctx), TEE_MALLOC_FILL_ZERO);
	if (!ctx)
		return TEE_ERROR_OUT_OF_MEMORY;

	res = get_hmac_key(&key_handle, &ctx->key_is_hw_backed);
	if (res != TEE_SUCCESS) {
		TEE_Free(ctx);
		return res;
	}

	/* One HMAC-SHA256 operation, allocated once per session and reused
	 * across every CLEAR/APPEND_DATA/GET_FINAL call the client makes.
	 * TEE_MACInit() (below, and in cmd_clear()) is what actually
	 * (re)starts a fresh message on it -- not re-allocating each time. */
	res = TEE_AllocateOperation(&ctx->mac_op, TEE_ALG_HMAC_SHA256,
				     TEE_MODE_MAC, HMAC_KEY_BITS);
	if (res != TEE_SUCCESS) {
		EMSG("imx93-hmac-ta: TEE_AllocateOperation failed: 0x%x", res);
		TEE_CloseObject(key_handle);
		TEE_Free(ctx);
		return res;
	}

	res = TEE_SetOperationKey(ctx->mac_op, key_handle);
	/* The operation copies whatever it needs from the key object at this
	 * point -- our standalone handle to it is no longer needed. */
	TEE_CloseObject(key_handle);
	if (res != TEE_SUCCESS) {
		EMSG("imx93-hmac-ta: TEE_SetOperationKey failed: 0x%x", res);
		TEE_FreeOperation(ctx->mac_op);
		TEE_Free(ctx);
		return res;
	}

	/* Start the first message immediately, so a client that calls
	 * APPEND_DATA without an explicit CLEAR first still gets correct,
	 * well-defined behaviour (a fresh stream) instead of an error. */
	TEE_MACInit(ctx->mac_op, NULL, 0);

	IMSG("imx93-hmac-ta: session opened (key: %s)",
	     ctx->key_is_hw_backed ? "secure-storage-backed" : "embedded dummy (testing)");

	*sess_ctx = ctx;
	return TEE_SUCCESS;
}

void TA_CloseSessionEntryPoint(void *sess_ctx)
{
	struct hmac_session_ctx *ctx = sess_ctx;

	IMSG("imx93-hmac-ta: session closed");
	TEE_FreeOperation(ctx->mac_op);
	TEE_Free(ctx);
}

/* HMAC_Clear: discard whatever was appended so far and start a brand-new
 * message with the SAME key. Re-running TEE_MACInit on an
 * already-initialized MAC operation is explicitly valid per the
 * GlobalPlatform spec -- this is the whole "clear the current HMAC and
 * context so I can open a new stream" requirement, in one call. */
static TEE_Result cmd_clear(struct hmac_session_ctx *ctx, uint32_t param_types)
{
	uint32_t exp_pt = TEE_PARAM_TYPES(TEE_PARAM_TYPE_NONE, TEE_PARAM_TYPE_NONE,
					   TEE_PARAM_TYPE_NONE, TEE_PARAM_TYPE_NONE);
	if (param_types != exp_pt)
		return TEE_ERROR_BAD_PARAMETERS;

	IMSG("imx93-hmac-ta: clearing -- starting a fresh HMAC stream");
	TEE_MACInit(ctx->mac_op, NULL, 0);
	return TEE_SUCCESS;
}

/* HMAC_Append_Data: feed one chunk into the ongoing computation. Callable
 * any number of times in a row -- HMAC-SHA256 is a true streaming
 * algorithm, so one call with a whole file and a thousand one-byte calls
 * produce an IDENTICAL final digest. This is what lets the CA HMAC a
 * file of ANY size without ever holding the whole thing in Secure World
 * memory at once. */
static TEE_Result cmd_append_data(struct hmac_session_ctx *ctx,
				   uint32_t param_types, TEE_Param params[4])
{
	uint32_t exp_pt = TEE_PARAM_TYPES(TEE_PARAM_TYPE_MEMREF_INPUT,
					   TEE_PARAM_TYPE_NONE,
					   TEE_PARAM_TYPE_NONE,
					   TEE_PARAM_TYPE_NONE);
	if (param_types != exp_pt)
		return TEE_ERROR_BAD_PARAMETERS;

	if (params[0].memref.size == 0)
		return TEE_SUCCESS; /* nothing to do, not an error */

	IMSG("imx93-hmac-ta: appending %u byte(s) to the ongoing HMAC",
	     params[0].memref.size);

	/* TEE_MACUpdate has no return value in the GP API -- any underlying
	 * failure only surfaces later, at TEE_MACComputeFinal time. */
	TEE_MACUpdate(ctx->mac_op, params[0].memref.buffer,
		      params[0].memref.size);
	return TEE_SUCCESS;
}

/* HMAC_Get_Final: finish the computation and hand back the 32-byte
 * digest. Re-arms the operation with a fresh TEE_MACInit() immediately
 * afterward, so a client can start a NEW message right away without an
 * explicit CLEAR call first (CLEAR stays available for explicitness). */
static TEE_Result cmd_get_final(struct hmac_session_ctx *ctx,
				 uint32_t param_types, TEE_Param params[4])
{
	TEE_Result res;
	uint32_t exp_pt = TEE_PARAM_TYPES(TEE_PARAM_TYPE_MEMREF_OUTPUT,
					   TEE_PARAM_TYPE_NONE,
					   TEE_PARAM_TYPE_NONE,
					   TEE_PARAM_TYPE_NONE);
	if (param_types != exp_pt)
		return TEE_ERROR_BAD_PARAMETERS;

	if (params[0].memref.size < TA_HMAC_DIGEST_SIZE) {
		/* GP convention: report the real required size back to the
		 * caller even on a short-buffer failure. */
		params[0].memref.size = TA_HMAC_DIGEST_SIZE;
		return TEE_ERROR_SHORT_BUFFER;
	}

	/* Finalize with zero extra input -- everything was already fed in
	 * via prior APPEND_DATA calls. (TEE_MACComputeFinal also accepts a
	 * final trailing chunk here; unused, to keep append/final
	 * unambiguous for callers.) */
	res = TEE_MACComputeFinal(ctx->mac_op, NULL, 0,
				   params[0].memref.buffer,
				   &params[0].memref.size);
	if (res != TEE_SUCCESS) {
		EMSG("imx93-hmac-ta: TEE_MACComputeFinal failed: 0x%x", res);
		return res;
	}

	IMSG("imx93-hmac-ta: HMAC finalized (%u bytes)", params[0].memref.size);

	TEE_MACInit(ctx->mac_op, NULL, 0);
	return TEE_SUCCESS;
}

TEE_Result TA_InvokeCommandEntryPoint(void *sess_ctx, uint32_t cmd_id,
				       uint32_t param_types,
				       TEE_Param params[4])
{
	struct hmac_session_ctx *ctx = sess_ctx;

	switch (cmd_id) {
	case TA_HMAC_CMD_CLEAR:
		return cmd_clear(ctx, param_types);
	case TA_HMAC_CMD_APPEND_DATA:
		return cmd_append_data(ctx, param_types, params);
	case TA_HMAC_CMD_GET_FINAL:
		return cmd_get_final(ctx, param_types, params);
	default:
		return TEE_ERROR_BAD_PARAMETERS;
	}
}
