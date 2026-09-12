# TrustZone & OP-TEE Hands-On — FRDM-IMX93

Applies the concepts from **`ARM TrustZone — Hardware-Enforced Security
Barriers`** — Obsidian note at
`~/Documents/Setup/Static/Obsidian Vault/Learning/Security/BOOTLIN/06-arm-trustzone/ARM TrustZone Hardware-Enforced Security Barriers.md`
(Bootlin's Embedded Linux Security course, module 6) — directly to **this board**
— not QEMU. Every lab below runs on the real FRDM-IMX93, using the exact BSP
this layer already builds (`imx-image-sec-min`/`imx-image-sec-full` both
`inherit`/install OP-TEE by default).

> This doc assumes you've read the source module at least once — it explains
> *why* each piece exists (worlds, ELs, SCR.NS, `smc`, TF-A's BL naming, TA
> types, use cases, real CVEs). Here we skip straight to **where each concept
> physically lives on this board**, and how to touch it.

---

## 0. Concept → evidence, on this exact board

Everything in the source module has a concrete, inspectable counterpart in
this BSP. This table is the map; the rest of the document is the tour.

| Concept (course) | On FRDM-IMX93, in this repo/BSP |
|---|---|
| EL3 Secure Monitor | **TF-A `BL31`** — `meta-imx/meta-imx-bsp/recipes-bsp/imx-atf/imx-atf_2.10.bb`. This layer's own [`recipes-bsp/imx-atf/imx-atf_%.bbappend`](../../recipes-bsp/imx-atf/imx-atf_%25.bbappend) adds a patch that prints an `[IMX93-CUSTOM]` banner *from inside BL31* at every stage transition — see [§1](#1-lab-1-read-the-worlds-off-your-own-serial-console) |
| BL2 / Trusted Boot firmware | **U-Boot SPL** (`board/freescale/imx93_frdm/spl.c`) — same bbappend pulls in a matching SPL banner patch, [`0040-...-spl-Add-IMX93-CUSTOM-boot-stage-banner.patch`](../../recipes-bsp/u-boot/u-boot-imx/0040-imx93_frdm-spl-Add-IMX93-CUSTOM-boot-stage-banner.patch) |
| BL32 / Trusted OS | **OP-TEE OS**, built for `PLATFORM=imx-mx93evk` (see [§0.1](#01-a-frdm-specific-wrinkle-platform_flavor)) |
| BL33 / normal-world bootloader | **U-Boot proper** — this layer's other patches (`netflash`, `net_first_bootcmd`) live *here*, entirely in Normal World, after the TrustZone split is already established |
| `MACHINE_FEATURES` gating BL32 | `imx93-11x11-lpddr4x-frdm.conf` gets `optee` in `MACHINE_FEATURES` by default (NXP has deprecated turning it off) → `imx-atf_2.10.bb` sets `BUILD_OPTEE = "true"` → BL31 gets built **twice**, once plain and once `SPD=opteed` — the `-optee` variant is what actually ships in `imx-boot` |
| `packagegroup-fsl-optee-imx` | Already in this layer's `imx-image-sec-min.bb` (`IMAGE_INSTALL`) — pulls `optee-client` (libteec, `tee-supplicant`), `optee-os` (firmware + TA devkit), `optee-test` (`xtest` + its test TAs) |
| REE FS TAs / `tee-supplicant` | `optee-client_4.2.0.imx.bb` → `optee-client-imx.inc` → `require`s **meta-arm's** generic `recipes-security/optee/optee-client.inc` (not meta-freescale's `optee-client-fslc.inc`). That one ships a **templated** systemd unit, `tee-supplicant@.service`, started per-device by a udev rule the instant `/dev/teeprivN` appears (`ENV{SYSTEMD_WANTS}+="tee-supplicant@%k.service"`) — there is no plain `tee-supplicant.service` on this image. Check it as `systemctl status tee-supplicant@teepriv0.service` |
| TA signing key / `default_ta.pem` | This BSP's `optee-os-fslc-imx.inc` does **not** override `TA_SIGN_KEY` — every TA on this board, including `xtest`'s, is signed with upstream OP-TEE's public development key. See [§4](#4-lab-4-find-and-replace-the-ta-signing-key) |
| Trusted Applications (usermode, S-EL0) | None ship by default beyond `xtest`'s internal test TAs — **`optee_example_hello_world` is not in this image**, and can't simply be bolted on (see [§2.1](#21-why-not-just-add-optee-examples)). §3 builds one from scratch, the right way for this exact BSP. |

### 0.1 A FRDM-specific wrinkle: `PLATFORM_FLAVOR`

OP-TEE OS doesn't know a dedicated "FRDM" platform for i.MX93 — NXP's
`optee-os-fslc-imx.inc` maps `MACHINE=imx93frdm` (or
`imx93-11x11-lpddr4x-frdm`) to `PLATFORM_FLAVOR = "mx93evk"`:

```
PLATFORM_FLAVOR:mx93-nxp-bsp = "mx93evk"
```

So OP-TEE OS is built with `PLATFORM=imx-mx93evk` regardless of which i.MX93
board variant you're actually holding — OP-TEE's platform code cares about
the **SoC**, not the carrier board (peripherals/PMIC differences are a
device-tree/Linux-driver concern, not a Secure World one on this chip). Worth
knowing before you go looking for an `mx93frdm` string in the OP-TEE source
tree and don't find one.

---

## 1. Lab 1 — Read the worlds off your own serial console

The course's Lab 1 has you match boot-log lines to BL names in a QEMU
console. On this board **you already ship code that does exactly that**,
because this layer added boot-stage banners for exactly this purpose (see
this repo's own README, "CM33/boot" sections) — you don't need to add
anything, just connect and read.

Power-cycle the board with a serial console attached (`115200 8N1`) and watch
for three `[IMX93-CUSTOM]` banners in order:

```text
********************************************************
*  [IMX93-CUSTOM] NXP i.MX93 FRDM Security Testing Image
*  Stage   : BL2 - SPL (Secondary Program Loader)
*  Loads   : BL31 (ATF) + BL32 (OP-TEE) + BL33 (U-Boot)
********************************************************
[IMX93-CUSTOM] BL2: initializing PMIC...
[IMX93-CUSTOM] BL2: initializing DDR...
[IMX93-CUSTOM] BL2: starting M33 co-processor...
********************************************************
*  [IMX93-CUSTOM] BL2 complete
*  Handoff : loading BL31 (ATF) + BL32 (OP-TEE) + BL33 (U-Boot)
********************************************************
```
↑ this is **BL2 = U-Boot SPL**, from
[`0040-imx93_frdm-spl-Add-IMX93-CUSTOM-boot-stage-banner.patch`](../../recipes-bsp/u-boot/u-boot-imx/0040-imx93_frdm-spl-Add-IMX93-CUSTOM-boot-stage-banner.patch)
— note it explicitly names the handoff to BL31/BL32/BL33, i.e. it's the code
that transfers control **out of Secure World's first stage**.

```text
********************************************************
*  [IMX93-CUSTOM] NXP i.MX93 FRDM Security Testing Image
*  Stage   : BL31 - EL3 Runtime Firmware (Secure Monitor)
*  SPD     : OP-TEE enabled (BL32 @ 0x...)
*  BL33    : U-Boot @ 0x...
********************************************************
[IMX93-CUSTOM] BL31: arch setup -- MMU, GPIO, TRDC
[IMX93-CUSTOM] BL31: arch setup done -- MMU on, TRDC ready
[IMX93-CUSTOM] BL31: platform setup -- timers, GIC, DRAM
[IMX93-CUSTOM] BL31: platform setup complete
********************************************************
*  [IMX93-CUSTOM] BL31 complete
*  Handoff : OP-TEE (BL32) -> U-Boot (BL33)
********************************************************
```
↑ this is **BL31 = the actual EL3 Secure Monitor** (from
[`0001-imx93-bl31-Add-IMX93-CUSTOM-boot-stage-banner.patch`](../../recipes-bsp/imx-atf/imx-atf/0001-imx93-bl31-Add-IMX93-CUSTOM-boot-stage-banner.patch)).
`SPD : OP-TEE enabled` is printed **only** because this ATF build was
compiled `SPD=opteed` (§0's `BUILD_OPTEE` logic) — if you ever build with
`MACHINE_FEATURES:remove = "optee"`, this exact line changes to `no TEE,
direct to BL33` and the handoff line drops the OP-TEE hop. That's the course's
§4 table rendered as a live log line, not a diagram.

**Checklist**, straight from the course's Lab 1:
- Which stages logged and then are **gone** from memory? → BL1 (silicon ROM,
  never printed anything you can see) and BL2 (SPL — the banner above is the
  *last* thing it does before jumping away).
- Which stay **resident** and are still running right now, backing every
  `smc` you'll make in §2? → BL31 (the monitor itself) and BL32/OP-TEE
  (silently, since this board sets `CFG_TEE_CORE_LOG_LEVEL=0` — see the box
  below).

> **Why you won't see OP-TEE's own `I/TC: OP-TEE version ...` banner** (unlike
> the course's QEMU lab): `meta-freescale/recipes-security/optee-imx/optee-os-fslc.inc`
> builds this board's OP-TEE with `CFG_TEE_CORE_LOG_LEVEL=0` and
> `CFG_TEE_TA_LOG_LEVEL=0` — the quietest setting, deliberately, for a
> production-shaped image. OP-TEE is still there and still running (§2 proves
> it) — it's simply been told not to narrate. If you want that banner back for
> learning purposes, add a `.bbappend` to `optee-os_4.2.0.imx.bb` bumping
> `CFG_TEE_CORE_LOG_LEVEL` (0=none … 4=very verbose) via `EXTRA_OEMAKE`, and
> rebuild BL32.

---

## 2. Lab 2 — Observe world transitions from Linux

SSH or serial-login as `root` (passwordless — this image's `debug-tweaks`).

```bash
# The Normal-world TEE driver found OP-TEE via smc probing at kernel boot:
dmesg | grep -i optee
# → "optee: probing for conduit method" / "optee: revision x.y"
#   (the SMC probe IS the svc→smc round trip from the course's §3.2 diagram —
#    it happens once, at kernel init, before any userland exists)

# The doorway devices from the course's §7 (TEE exposes services via TAs,
# never directly) -- /dev/tee0 for clients, /dev/teepriv0 for tee-supplicant:
ls -l /dev/tee*

# tee-supplicant is already running -- it's the Normal-world daemon that
# would fetch a REE FS TA's .ta file from the filesystem on your behalf.
# It's a udev-instantiated unit (tee-supplicant@<kernel dev>.service), NOT
# a plain "tee-supplicant.service" -- `systemctl status tee-supplicant`
# will say "could not be found" even though it's running fine:
systemctl status tee-supplicant@teepriv0.service

# Run OP-TEE's own test suite: thousands of svc -> smc -> S-EL1 round trips,
# each one entering and leaving Secure World:
xtest | tail -20
# expect: "N subtests of which 0 failed"
```

Every `xtest` subtest is a live instance of the course's §3.2 sequence
diagram: your shell (EL0) → `xtest` binary → `ioctl` on `/dev/tee0` → `svc` →
Linux TEE driver (EL1) → `smc` → **BL31 monitor (EL3, resident, printed the
banner above)** flips `SCR.NS` → OP-TEE (S-EL1) → one of `xtest`'s own
internal test TAs (S-EL0) → result → `SCR.NS` back → return through the same
chain. `xtest` alone proves BL31 and BL32 are alive and correctly wired,
without you writing a line of code.

---

## 3. Building your own Trusted Application

### 3.1 Why not just add `optee-examples`?

The obvious move — add the community `optee-examples` recipe
(`optee_example_hello_world` et al., from `meta-arm-bsp`) to
`IMAGE_INSTALL` — **doesn't work on this BSP**, for two independent reasons
worth knowing before you burn an afternoon on it:

1. `meta-arm/meta-arm/recipes-security/optee/optee.inc` sets
   `COMPATIBLE_MACHINE ?= "invalid"`, explicitly listing only
   `qemuarm`/`qemuarm64` as valid — `imx93frdm` isn't on that list, so bitbake
   refuses to build it as-is.
2. Even if you overrode that: meta-arm's `optee.inc` expects the TA dev kit
   at `${STAGING_INCDIR}/optee/export-user_ta` (**no** arch suffix), but this
   BSP's `optee-os-fslc.inc` (the one actually building your board's BL32)
   installs it at `${STAGING_INCDIR}/optee/export-user_ta_${OPTEE_ARCH}`
   (**with** an `arm64` suffix) — a straight path mismatch between two
   layers' conventions for the same concept.

`xtest` (from `optee-test_4.2.0.imx.bb`, already in your image) uses the
*correct*, NXP-BSP-native path — that recipe is the right template to copy,
not meta-arm's.

### 3.2 A minimal TA + client, matching this BSP's own conventions

This builds `imx93-hello-ta`: a TA that increments a number **inside the
Secure world** (the exact shape of the course's Lab 4/hello-world exercise),
packaged as a normal Yocto recipe for this layer, using the same
`TA_DEV_KIT_DIR` path `xtest` itself uses.

Create this layout in a new `recipes-security/imx93-hello-ta/` directory:

```
recipes-security/imx93-hello-ta/
├── imx93-hello-ta_1.0.bb
└── files/
    ├── ta/
    │   ├── Makefile
    │   ├── sub.mk
    │   ├── include/imx93_hello_ta.h
    │   └── imx93_hello_ta.c
    └── host/
        ├── Makefile
        └── main.c
```

**`files/ta/include/imx93_hello_ta.h`** — every TA is identified by a UUID;
generate your own (`python3 -c "import uuid; print(uuid.uuid4())"`) rather
than reusing the one below:

```c
#ifndef TA_IMX93_HELLO_H
#define TA_IMX93_HELLO_H

/* Replace with a UUID you generated yourself. */
#define TA_IMX93_HELLO_UUID \
	{ 0x3f8577d8, 0x1f83, 0x4c25, \
		{ 0x92, 0x5b, 0x93, 0x1f, 0x4c, 0x2e, 0x77, 0x02 } }

#define TA_IMX93_HELLO_CMD_INC_VALUE	0

#endif
```

**`files/ta/imx93_hello_ta.c`** — the Secure-world side (**S-EL0**):

```c
#include <tee_internal_api.h>
#include <tee_internal_api_extensions.h>
#include <imx93_hello_ta.h>

TEE_Result TA_CreateEntryPoint(void)
{
	return TEE_SUCCESS;
}

void TA_DestroyEntryPoint(void)
{
}

TEE_Result TA_OpenSessionEntryPoint(uint32_t param_types __unused,
				     TEE_Param params[4] __unused,
				     void **sess_ctx __unused)
{
	IMSG("imx93-hello-ta: session opened");
	return TEE_SUCCESS;
}

void TA_CloseSessionEntryPoint(void *sess_ctx __unused)
{
	IMSG("imx93-hello-ta: session closed");
}

static TEE_Result inc_value(uint32_t param_types, TEE_Param params[4])
{
	uint32_t exp_pt = TEE_PARAM_TYPES(TEE_PARAM_TYPE_VALUE_INOUT,
					   TEE_PARAM_TYPE_NONE,
					   TEE_PARAM_TYPE_NONE,
					   TEE_PARAM_TYPE_NONE);
	if (param_types != exp_pt)
		return TEE_ERROR_BAD_PARAMETERS;

	IMSG("imx93-hello-ta: incrementing %u inside the secure world",
	     params[0].value.a);
	params[0].value.a++;
	return TEE_SUCCESS;
}

TEE_Result TA_InvokeCommandEntryPoint(void *sess_ctx __unused, uint32_t cmd_id,
				       uint32_t param_types,
				       TEE_Param params[4])
{
	switch (cmd_id) {
	case TA_IMX93_HELLO_CMD_INC_VALUE:
		return inc_value(param_types, params);
	default:
		return TEE_ERROR_BAD_PARAMETERS;
	}
}
```

**`files/ta/sub.mk`**:

```makefile
global-incdirs-y += include
srcs-y += imx93_hello_ta.c
```

**`files/ta/Makefile`** — pulls in OP-TEE's own TA build system, exactly like
every real OP-TEE TA does:

```makefile
BINARY = 3f8577d8-1f83-4c25-925b-931f4c2e7702

-include $(TA_DEV_KIT_DIR)/mk/ta_dev_kit.mk

clean:
	@$(RM) -f $(sub-dirs-out) $(cleanfiles)
```

(`BINARY` must match your UUID, dash-formatted — this is the filename
`ta_dev_kit.mk` gives the signed `.ta` output.)

**`files/host/main.c`** — the Normal-world side (**EL0**), talking to the TA
through `libteec` (this is the `svc`→`ioctl(/dev/tee0)` path from §2, wrapped
by the client library):

```c
#include <err.h>
#include <stdio.h>
#include <string.h>

#include <tee_client_api.h>
#include <imx93_hello_ta.h>

int main(void)
{
	TEEC_Result res;
	TEEC_Context ctx;
	TEEC_Session sess;
	TEEC_Operation op;
	TEEC_UUID uuid = TA_IMX93_HELLO_UUID;
	uint32_t err_origin;

	res = TEEC_InitializeContext(NULL, &ctx);
	if (res != TEEC_SUCCESS)
		errx(1, "TEEC_InitializeContext failed: 0x%x", res);

	res = TEEC_OpenSession(&ctx, &sess, &uuid, TEEC_LOGIN_PUBLIC,
				NULL, NULL, &err_origin);
	if (res != TEEC_SUCCESS)
		errx(1, "TEEC_OpenSession failed: 0x%x origin 0x%x",
		     res, err_origin);

	memset(&op, 0, sizeof(op));
	op.paramTypes = TEEC_PARAM_TYPES(TEEC_VALUE_INOUT, TEEC_NONE,
					  TEEC_NONE, TEEC_NONE);
	op.params[0].value.a = 42;

	printf("Invoking TA to increment %u\n", op.params[0].value.a);
	res = TEEC_InvokeCommand(&sess, TA_IMX93_HELLO_CMD_INC_VALUE, &op,
				  &err_origin);
	if (res != TEEC_SUCCESS)
		errx(1, "TEEC_InvokeCommand failed: 0x%x origin 0x%x",
		     res, err_origin);
	printf("TA incremented value to %u\n", op.params[0].value.a);

	TEEC_CloseSession(&sess);
	TEEC_FinalizeContext(&ctx);
	return 0;
}
```

**`files/host/Makefile`** — plain cross-compile, `CC`/`CFLAGS`/`LDFLAGS`
supplied by the recipe (same pattern this layer's `hello-imx93`/`led-ctrl`
recipes already use):

```makefile
CC ?= gcc
BINARY = imx93-hello-ca

all: $(BINARY)

$(BINARY): main.c
	$(CC) $(CFLAGS) -I../ta/include -o $@ $< $(LDFLAGS) -lteec

clean:
	rm -f $(BINARY)
```

**`imx93-hello-ta_1.0.bb`** — the recipe. Mirrors exactly what
`optee-test-fslc.inc` does for `xtest` (`TA_DEV_KIT_DIR` path, `OPTEE_ARCH`,
`CROSS_COMPILE`), so it builds against the same devkit your board's `xtest`
already uses successfully:

```bitbake
SUMMARY = "Minimal OP-TEE Trusted Application + client demo for FRDM-IMX93"
DESCRIPTION = "TrustZone/OP-TEE hands-on demo: a TA that increments a value \
inside the secure world (S-EL0), invoked by a normal-world client via \
libteec. See Docs/optee-trustzone-hands-on/README.md in this layer."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://ta/Makefile \
    file://ta/sub.mk \
    file://ta/include/imx93_hello_ta.h \
    file://ta/imx93_hello_ta.c \
    file://host/Makefile \
    file://host/main.c \
"

S = "${WORKDIR}"

DEPENDS = "optee-client optee-os"
RDEPENDS:${PN} = "optee-client"

OPTEE_ARCH:arm = "arm32"
OPTEE_ARCH:aarch64 = "arm64"

do_compile() {
    oe_runmake -C ${S}/ta \
        CROSS_COMPILE=${HOST_PREFIX} \
        TA_DEV_KIT_DIR=${STAGING_INCDIR}/optee/export-user_ta_${OPTEE_ARCH}

    oe_runmake -C ${S}/host \
        CC="${CC}" \
        CFLAGS="${CFLAGS} --sysroot=${STAGING_DIR_HOST}" \
        LDFLAGS="${LDFLAGS} --sysroot=${STAGING_DIR_HOST}"
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${S}/host/imx93-hello-ca ${D}${bindir}/

    install -d ${D}${nonarch_base_libdir}/optee_armtz
    install -m 0444 ${S}/ta/*.ta ${D}${nonarch_base_libdir}/optee_armtz/
}

FILES:${PN} = " \
    ${bindir}/imx93-hello-ca \
    ${nonarch_base_libdir}/optee_armtz \
"
```

Add it to an image (`imx-image-sec-min.bb`'s `IMAGE_INSTALL`, alongside
`hello-imx93`/`led-ctrl`) and rebuild. On the board:

```bash
imx93-hello-ca
# Invoking TA to increment 42
# TA incremented value to 43
```

**Narrate the journey**, per the course's Lab 3: `imx93-hello-ca` (EL0) →
`ioctl(/dev/tee0)` → `svc` → Linux TEE driver (EL1) → `smc` → **BL31 monitor
(EL3)** flips `SCR.NS` → **OP-TEE (S-EL1)** loads/dispatches your TA by UUID →
**your TA (S-EL0)** runs `inc_value()`, prints `IMSG` (invisible right now —
`CFG_TEE_CORE_LOG_LEVEL=0`, §1's box) → result flows back the same chain. An
integer you own crossed four privilege levels and the world barrier, on your
own board.

---

## 4. Lab 4 — Find and replace the TA signing key

The course's warning (§8/Lab 5 in the source module) is not hypothetical on
this board — verify it yourself:

```bash
# On the HOST, inside the OP-TEE OS build's work directory (after building):
find tmp/work/*/optee-os*/*/git/keys/ -name '*.pem'
# default_ta.pem is upstream OP-TEE's PUBLIC development key --
# every TA built by this BSP today, including xtest's, is signed with it.
```

This BSP's `optee-os-fslc-imx.inc` does not pass a `TA_SIGN_KEY` override, so
the default applies silently. Before shipping this board with real secrets
behind a TA (§5 below), generate your own key and override it — the pattern
matches every other patch in this layer (a `.bbappend`, not a fork):

```bitbake
# recipes-security/optee/optee-os_4.2.0.imx.bbappend
FILESEXTRAPATHS:prepend := "${THISDIR}/${BPN}:"
SRC_URI += "file://my_ta_key.pem"
EXTRA_OEMAKE += "TA_SIGN_KEY=${WORKDIR}/my_ta_key.pem"
```

```bash
openssl genpkey -algorithm rsa -pkeyopt rsa_keygen_bits:3072 -out my_ta_key.pem
```

**Lesson, unchanged from the course:** with the default key still in place,
*anyone* — not just you — can build a `.ta` file this board's OP-TEE will
load and run. The TrustZone hardware barrier is intact; the PKI step guarding
entry through it isn't, until you do this.

---

## 5. Capstone, adapted to this repo: protect the STM32 firmware signing key

The source module's capstone protects a gateway's MQTT device key. This
layer has its own real analogue already in the codebase:
**`fota-bootloader`** flashes new STM32 application firmware onto the target
over UART, and (per the repo's own README) currently ships with no signing
of the `.bin` it flashes — anything dropped into
`/lib/firmware/stm32f103/` gets pushed to the STM32 as-is.

Work through the course's five capstone steps against **this** scenario:

1. **Architecture on paper**: redraw §2's two-world diagram for this board —
   place `fota-bootloader` (EL0), Linux (EL1), TF-A (EL3, already on your
   serial console per §1), OP-TEE (S-EL1), and a new **`fota-signing` TA**
   (S-EL0) holding the firmware-signing private key. Mark every boundary a
   forged STM32 image would have to cross to get flashed.
2. **Design the API**: the TA exposes exactly `SIGN_FIRMWARE` (hash the
   `.bin`, return a signature) — no `EXPORT_PRIVATE_KEY`. `fota-bootloader`
   (already RDEPENDS-linked to `stm32f103-firmware` in this layer) would call
   this instead of trusting whatever `.bin` lands in the watched directory,
   and the STM32-side bootloader (out of scope here, but conceptually) would
   verify the signature before accepting an update.
3. **Walk the call**, naming every hop (`svc`, `/dev/tee0`,
   `smc`, `SCR.NS`, S-EL1 dispatch, S-EL0 TA) — same shape as §3.2's
   `imx93-hello-ca` walk, just with `SIGN_FIRMWARE` in place of
   `INC_VALUE`.
4. **Threat-model it**: `fota-bootloader` already runs with `AUTOREV` (see
   this repo's own README — an *open* item, not yet pinned) — what does an
   attacker who compromises the upstream `CPP_Application`/`FOTA` GitHub
   repos gain here versus what TrustZone still denies them? (They can get
   *unsigned/attacker-chosen firmware built into the image* — a supply-chain
   problem no TA fixes; they still can't extract the signing key itself if
   step 2's API has no export path.)
5. **Honesty section**: which of §10's three residual-risk classes (TA bug,
   OP-TEE/monitor bug, SoC-specific world-memory misconfiguration) would you
   most need to audit for *specifically on i.MX93*, given this SoC's EdgeLock
   Enclave (ELE) also participates in key management here (this layer's
   `imx-image-sec-min.bb` already installs `openssl-provider-se050`/
   `plug-and-trust-ecc` from `packagegroup-imx-security`) — i.e., where does
   ELE's own secure-element boundary sit relative to the OP-TEE boundary you
   just drew in step 1?

No sample answers this time — this one's really yours, on real hardware you
can actually go verify each claim against.

---

## References

- Concept source: `ARM TrustZone — Hardware-Enforced Security Barriers`, Obsidian note at `~/Documents/Setup/Static/Obsidian Vault/Learning/Security/BOOTLIN/06-arm-trustzone/` (Bootlin course module 6, slides 76–93) — read this first for *why*; this doc is the *where/how* on this board.
- [`../imx-yocto-project-users-guide.md`](../imx-yocto-project-users-guide.md) §5.6.9 — how OP-TEE enablement is toggled BSP-wide (`meta-imx/meta-imx-bsp/conf/layer.conf`).
- This repo's top-level `README.md` — `packagegroup-fsl-optee-imx`, `packagegroup-imx-security` (ELE), and `imx-atf_%.bbappend`/`u-boot-imx_2024.04.bbappend` (the boot-stage banner patches §1 reads).
- Recipes actually inspected while writing this doc (for anyone re-verifying
  against a future BSP bump): `meta-imx/meta-imx-bsp/recipes-security/optee/{optee-os_4.2.0.imx.bb,optee-os-fslc-imx.inc,optee-test_4.2.0.imx.bb,optee-client_4.2.0.imx.bb}`, `meta-freescale/recipes-security/optee-imx/{optee-fslc.inc,optee-os-fslc.inc,optee-client-fslc.inc,optee-test-fslc.inc}`, `meta-imx/meta-imx-bsp/recipes-bsp/imx-atf/imx-atf_2.10.bb`, `meta-arm/meta-arm/recipes-security/optee/optee.inc`, `meta-arm/meta-arm-bsp/recipes-security/optee/optee-examples_4.0.0.bb`.
