/*
 * Mandatory TA property header -- see imx93-hello-ta's copy of this file
 * for the full explanation of why this exists at all (ta_dev_kit.mk
 * unconditionally compiles a user_ta_header.c that #includes this).
 */
#ifndef USER_TA_HEADER_DEFINES_H
#define USER_TA_HEADER_DEFINES_H

#include <imx93_hmac_ta.h>

#define TA_UUID TA_IMX93_HMAC_UUID

/* TA_FLAG_SINGLE_INSTANCE + TA_FLAG_MULTI_SESSION: one loaded TA instance,
 * shared across every session -- but each SESSION still gets its own
 * hmac_session_ctx (see imx93_hmac_ta.c) with its own TEE_OperationHandle,
 * so two clients HMAC-ing different data concurrently do not interfere
 * with each other's streaming state. Only the underlying HMAC KEY object
 * is shared TA-instance-wide (created once, on first use). */
#define TA_FLAGS (TA_FLAG_EXEC_DDR | TA_FLAG_SINGLE_INSTANCE | TA_FLAG_MULTI_SESSION)

#define TA_STACK_SIZE (2 * 1024)

/* A bit more heap than imx93-hello-ta's: this TA holds a persistent-object
 * handle, a transient key object (briefly, during first-run key
 * generation), and an HMAC operation handle at once -- 32 KiB is still
 * comfortably more than needed, kept simple rather than tightly sized. */
#define TA_DATA_SIZE (32 * 1024)

#define TA_CURRENT_TA_EXT_PROPERTIES \
	{ "gp.ta.description", USER_TA_PROP_TYPE_STRING, \
		"imx93-hmac-ta: streaming HMAC-SHA256 inside the secure world" }, \
	{ "gp.ta.version", USER_TA_PROP_TYPE_U32, &(const uint32_t){ 0x0100 } }

#endif /* USER_TA_HEADER_DEFINES_H */
