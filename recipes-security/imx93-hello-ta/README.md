# imx93-hello-ta — build & test

Minimal OP-TEE Trusted Application + Normal-World client for FRDM-IMX93.
The TA increments a value **inside Secure World (S-EL0)**; the client
(`imx93-hello-ca`, Normal World EL0) sends it in and reads the result back.
See `files/ta/imx93_hello_ta.c` and `files/host/main.c` for the fully
commented source, and
[`../../Docs/optee-trustzone-hands-on.md`](../../Docs/optee-trustzone-hands-on.md)
for the TrustZone/OP-TEE concepts this recipe demonstrates.

This file is about **testing the recipe itself** — two ways, fastest first.

---

## Option A — standalone build + scp (fast iteration, no reflash)

Build just this recipe:

```bash
cd ~/Data/Yocto/IMX93/frdm-imx93
bitbake imx93-hello-ta
```

Its `do_install` output (exactly what would land on a rootfs) is staged at:

```bash
find tmp/work/armv8a-poky-linux/imx93-hello-ta/1.0/image -type f
```

→ two files: `usr/bin/imx93-hello-ca` and
`usr/lib/optee_armtz/<UUID>.ta` (UUID from `files/ta/include/imx93_hello_ta.h`).

Copy both to an already-running board — no reflash needed:

```bash
scp tmp/work/armv8a-poky-linux/imx93-hello-ta/1.0/image/usr/bin/imx93-hello-ca \
    root@192.168.1.101:/usr/bin/

scp tmp/work/armv8a-poky-linux/imx93-hello-ta/1.0/image/usr/lib/optee_armtz/*.ta \
    root@192.168.1.101:/lib/optee_armtz/
```

Run it on the board:

```bash
imx93-hello-ca
```

**Expected output:**
```
Invoking TA to increment 42
TA incremented value to 43
```

That `43` is the whole proof: the integer crossed EL0 → `svc` → EL1 (Linux
TEE driver) → `smc` → EL3 (BL31 monitor) → S-EL1 (OP-TEE) → S-EL0 (this TA),
got incremented **inside** Secure World, and came back.

Use this option every time you change the TA or CA source — it's a rebuild
+ two `scp`s, not a full image cycle.

## Option B — full image build (what ships permanently)

`imx93-hello-ta` is already listed in `imx-image-sec-min.bb`'s
`IMAGE_INSTALL` (and `imx-image-sec-full` inherits it via `require`). To get
it onto the rootfs "for real" — surviving a reflash, part of the shipped
image:

```bash
cd ~/Data/Yocto/IMX93/frdm-imx93
bitbake imx-image-sec-min
../sources/meta-imx93-customization/scripts/deploy-to-network.sh
```

Then either power-cycle the board (network-first boot, if flashed) or `run
netboot`/`run netflash` at the U-Boot prompt — see the top-level repo README
for the exact deploy workflow. Once booted, run `imx93-hello-ca` the same
way as Option A.

---

## Verifying it's actually loaded and working

`imx93-hello-ca` printing `43` (Option A/B above) is already the strongest
proof — a wrong UUID, a missing `.ta`, a dead OP-TEE driver, or a broken TA
all fail *before* that line prints, with a specific `TEEC_*` error (see
[Troubleshooting](#troubleshooting) below for what each one means). But if
you want to check each layer individually — useful when something DOES
fail and you need to narrow down which layer — here's how, cheapest checks
first:

**1. The `.ta` file is actually on the rootfs, named correctly:**
```bash
ls -l /lib/optee_armtz/
```
The filename (minus `.ta`) must match `TA_IMX93_HELLO_UUID` in
`files/ta/include/imx93_hello_ta.h` **exactly** — OP-TEE looks TAs up by
this filename, there is no other registration step. A typo here is the
single most common reason `imx93-hello-ca` fails with `origin 0x3`.

**2. The Normal-world TEE driver and doorway devices are alive:**
```bash
dmesg | grep -i optee
# → "optee: probing for conduit method" / "optee: revision x.y" /
#   "optee: initialized driver"
ls -l /dev/tee*
# → /dev/tee0 (client doorway) and /dev/teepriv0 (supplicant doorway)
```
If either of these looks wrong, nothing built by this recipe can work —
fix this first (see the OP-TEE hands-on doc's Lab 2 for what healthy output
looks like).

**3. `tee-supplicant` — the daemon that actually fetches the `.ta` file
off the rootfs on OP-TEE's behalf — is running:**
```bash
systemctl status tee-supplicant@teepriv0.service
```
It's a udev-instantiated unit (started the instant `/dev/teepriv0` appears,
not enabled the normal way), so it should already show `active (running)`
without you doing anything.

**Don't expect `journalctl -u tee-supplicant@teepriv0.service -f` to show
anything while you invoke the CA** — verified on real hardware while
writing this doc: it logs its own startup (`Started TEE Supplicant on
teepriv0`, plus a harmless `OPTARGS` notice from the unit file's unset
`EnvironmentFile`) and then stays completely silent during normal
operation, successful `.ta` fetches included. Its journal being quiet is
**not** a sign anything is wrong — it just isn't a useful place to look.
The CA's own printed output (step 4 below) is the real, reliable signal.

**4. The session actually reached your TA's code, not just OP-TEE core:**
this is the one thing you genuinely can't observe on this board *without* a
change, and it's worth understanding why: `imx93_hello_ta.c`'s `IMSG()`
calls (`"session opened"`, `"incrementing ... inside the secure world"`,
`"session closed"`) are real, correct code — but this BSP's `optee-os`
recipe builds OP-TEE with `CFG_TEE_CORE_LOG_LEVEL=0` and
`CFG_TEE_TA_LOG_LEVEL=0` (verified in
`meta-imx/meta-imx-bsp/recipes-security/optee/optee-os-common-imx.inc`) —
the quietest setting, so **every** TA's `IMSG()` output is compiled/gated
out on this image by default, not just this one's. `imx93-hello-ca` getting
back `43` already proves the TA ran (the increment happened somewhere, and
only the TA can do it) — the log line is confirmation for humans watching
the console, not something the mechanism depends on.

If you want to actually **see** those `IMSG()` lines (worth doing once, for
the "two worlds interleaving on one console" effect), turn the log level
back up. This layer already ships the `.bbappend` that does it, at
`recipes-security/optee/optee-os_%.imx.bbappend`:

```bitbake
# CFG_TEE_CORE_LOG_LEVEL: 0=none 1=error 2=info 3=debug 4=flow
# CFG_TEE_TA_LOG_LEVEL:   same scale, for TA-side IMSG()/DMSG()/etc.
# optee-os-common-imx.inc already sets both to 0 via EXTRA_OEMAKE:append --
# this bbappend's own :append runs AFTER it (bbappends parse after the
# recipe they extend), and make takes the LAST value for a variable
# repeated on its command line, so these two values win.
EXTRA_OEMAKE:append = " CFG_TEE_CORE_LOG_LEVEL=2 CFG_TEE_TA_LOG_LEVEL=3"
```

### Why TWO `.bbappend` files, not one

This layer ships both:
- `recipes-security/optee/optee-os_%.imx.bbappend` — raises the log level
  for BL32/OP-TEE **core** itself (its own boot banner, `I/TC: ...`).
- `recipes-security/optee/optee-os-tadevkit_%.imx.bbappend` — raises it for
  **`libutils.a`**, the library every out-of-tree TA (including this one)
  links against.

Both are required. Verified straight from OP-TEE's own build docs
(`mk/config.mk` in the fetched source, under
`tmp/work/imx93frdm-poky-linux/optee-os/4.2.0.imx/git/`):

> "If user-mode library libutils.a is built with `CFG_TEE_TA_LOG_LEVEL=0`,
> TA tracing is disabled regardless of the value of `CFG_TEE_TA_LOG_LEVEL`
> [used] when the TA is built."

In other words: whether `IMSG()` in *your* TA's code does anything at all
is decided when `optee-os-tadevkit` was built, not by anything in
`imx93-hello-ta_1.0.bb`. `optee-os` and `optee-os-tadevkit` are two
separate recipes that both `require optee-os-common-imx.inc` (which sets
`CFG_TEE_TA_LOG_LEVEL=0` for both) — a `.bbappend` matching one does **not**
match the other (`optee-os_%.imx.bbappend`'s wildcard doesn't reach
`optee-os-tadevkit_4.2.0.imx.bb` — verified with `fnmatch`, the extra
`-tadevkit` breaks the pattern). Miss the second `.bbappend` and you can
raise `optee-os`'s own level as high as you want — the core's own boot
banner will show up, but **every TA's `IMSG()` stays silent regardless**,
which is exactly the "SSH shows nothing, UART shows nothing either" symptom.

### Rebuild + re-flash (required — this changes firmware, not the rootfs)

Three things need rebuilding, in this order: both OP-TEE pieces, then this
recipe itself (so `imx93-hello-ca`'s `.ta` gets re-linked against the
now-verbose `libutils.a` — a stale, previously-built `.ta` keeps the old,
silent library baked in even after the two `.bbappend`s above exist):

```bash
cd ~/Data/Yocto/IMX93/frdm-imx93

# Force a real rebuild of all three -- a plain `bitbake <recipe>` may
# just reuse cached sstate built before these .bbappends existed.
bitbake optee-os-tadevkit -c cleansstate
bitbake optee-os -c cleansstate
bitbake imx93-hello-ta -c cleansstate

bitbake u-boot-imx     # repacks imx-boot with the rebuilt BL32 (+ BL31/SPL)
bitbake imx93-hello-ta # relink the TA against the now-verbose libutils.a
```

Re-flash just the bootloader with this layer's own `--flash-boot` (wipes the
whole card first — it's destructive by design, see its own confirmation
prompt; use a spare/scratch card or accept the full re-provision):

```bash
lsblk                                              # confirm the device node first
../sources/meta-imx93-customization/scripts/deploy-to-network.sh \
    --flash-boot /dev/sdX
```

Then push the freshly-relinked `imx93-hello-ca`/`.ta` the same way as
[Option A](#option-a--standalone-build--scp-fast-iteration-no-reflash)
above (they're rootfs content, not firmware — a plain `scp` is enough, no
second reflash needed for these two files specifically).

### Monitoring the calls — and why SSH can NEVER show this, on any board

**This is architectural, not a missing step: `IMSG()`/OP-TEE-core output
cannot reach SSH, `dmesg`, or `journalctl`, on this board or any TrustZone
board, no matter what you configure.** Verified in this exact BSP's OP-TEE
source (`core/arch/arm/plat-imx/main.c` + `platform_config.h`): the console
UART is registered as `MEM_AREA_IO_NSEC` and written via direct MMIO
register access from OP-TEE code — Secure World writes bytes straight to
the UART's hardware FIFO, the same physical wire Linux's serial driver
uses, but **completely bypassing** that Linux driver, the kernel's tty
layer, and therefore anything Linux itself could log. That's not a
missing feature — it's the same property that lets OP-TEE keep working
even if Linux has already crashed: it has no dependency on Linux's
software stack to produce output. The bytes exist nowhere except on the
physical UART wire, at the moment they're written.

So: a **physical (or USB) serial connection to the board's debug UART is
the only channel these logs can ever travel over.** If you only have SSH
access to this board and no serial cable, you structurally cannot see
`IMSG()` output — full stop, not a configuration problem to solve.

With a real serial connection in hand:

1. **Open the serial console first** (`115200 8N1`), before doing anything
   else — e.g. `screen /dev/ttyUSB0 115200` or `picocom -b 115200
   /dev/ttyUSB0` from the host.
2. **Power-cycle or reboot the board** and watch the whole boot sequence on
   that same connection — you should now see OP-TEE's own startup banner
   (`I/TC: OP-TEE version ...`), previously silent, right after the
   `[IMX93-CUSTOM] BL31 complete` banner from this layer's own ATF patch
   (see `../../Docs/optee-trustzone-hands-on.md`, Lab 1).
3. **Log in and run the CA on that same serial line** — not a separate SSH
   session:
   ```bash
   imx93-hello-ca
   ```
4. Watch for these three lines, interleaved with the CA's own `printf`
   output, at the exact moments the world-crossing happens. **Confirmed on
   real FRDM-IMX93 hardware** — this is the actual serial output from
   running this exact recipe, log level raised, freshly re-linked TA:
   ```
   root@imx93frdm:~# imx93-hello-ca
   I/TC: WARNING (insecure configuration): Failed to get monotonic counter for REE FS, using 0
   I/TC: WARNING (insecure configuration): Failed to commit dirh counter 2
   I/TA: imx93-hello-ta: session opened
   I/TA: imx93-hello-ta: incrementing 42 inside the secure world
   I/TA: imx93-hello-ta: session closed
   ```
   That interleaving — `imx93-hello-ca`'s own `printf` output (Normal
   World) landing on the same serial line as `I/TC:`/`I/TA:` (Secure
   World) — is the whole point: one CPU, two worlds, both writing to the
   wire you're watching, in the exact order execution actually crossed
   between them.

   **The two `I/TC: WARNING (insecure configuration): ...` lines above the
   TA's own output are normal, pre-existing, and not caused by this
   recipe or the log-level bump** — they're OP-TEE core's REE FS storage
   subsystem noting it has no hardware-backed monotonic counter available
   for anti-rollback protection on secure storage, so it falls back to an
   insecure default. This was always happening on this BSP's default
   configuration; raising `CFG_TEE_CORE_LOG_LEVEL` just made it visible
   for the first time. Harmless for this demo (it doesn't use secure
   storage at all) — only relevant if a TA you build later relies on
   secure storage's anti-rollback guarantee for something
   security-critical.

If you still see nothing on UART after all of the above: double check
*both* `.bbappend`s actually took effect —
```bash
bitbake-getvar -r optee-os EXTRA_OEMAKE
bitbake-getvar -r optee-os-tadevkit EXTRA_OEMAKE
```
each should show its respective `CFG_TEE_*_LOG_LEVEL` override as the
*last* occurrence in the printed string (GNU Make takes the last value for
a variable repeated on its command line) — and confirm `imx93-hello-ta`
was actually rebuilt *after* both of those (an old `.ta` file, still linked
against the previous silent `libutils.a`, is a common way to redo the
firmware work above and see no change).

---

## Troubleshooting

These are the **actual failures hit while developing this recipe**, kept
here because they're exactly what you'll see again if you fork this recipe
for your own TA and repeat any of these mistakes.

### `do_install`: `install: cannot stat '.../ta/*.ta': No such file or directory`

The TA never actually got built — `make` silently did nothing (or ran the
wrong target) instead of failing loudly. Almost always means
`TA_DEV_KIT_DIR` in `do_compile()` points at a directory that doesn't exist,
so `-include $(TA_DEV_KIT_DIR)/mk/ta_dev_kit.mk` in `files/ta/Makefile`
silently found nothing. Verify the real path with:

```bash
find tmp/work/*/imx93-hello-ta/1.0/recipe-sysroot/usr/include/optee -maxdepth 2
```

(This recipe now uses `${STAGING_INCDIR}/optee/export-user_ta` — **no** arch
suffix — because it `DEPENDS` on `optee-os-tadevkit`, not `optee-os`. An
older, unused meta-freescale `optee-os` recipe uses an arch-suffixed path
instead; if you ever see this error again after editing `DEPENDS`, check
which `optee-os`/`optee-os-tadevkit` variant actually built by inspecting
`tmp/work/imx93frdm-poky-linux/optee-os*/`, not just by reading the "obvious"
recipe file — there are multiple providers in this BSP with the same name.)

### `do_compile`: `fatal error: user_ta_header_defines.h: No such file or directory`

Every OP-TEE TA needs this file — it's not optional boilerplate.
`ta_dev_kit.mk` unconditionally compiles a `user_ta_header.c` (from inside
the TA devkit itself) that `#include`s it, to learn the TA's UUID
(`TA_UUID`), stack/heap size, and flags. It must sit under a directory
listed in `sub.mk`'s `global-incdirs-y` — here, `files/ta/include/`. See
`files/ta/include/user_ta_header_defines.h` for a fully commented template.

### `do_compile`: `aarch64-poky-linux-ld.bfd: cannot find libgcc.a`

`ta_dev_kit.mk`'s link step locates `libgcc.a` by running
`$(CC) $(LIBGCC_LOCATE_CFLAGS) -print-libgcc-file-name`. Without
`LIBGCC_LOCATE_CFLAGS` set to the same arch/toolchain flags the rest of the
build uses, that query can miss the right libgcc variant entirely. Fixed by
passing `LIBGCC_LOCATE_CFLAGS="${HOST_CC_ARCH}${TOOLCHAIN_OPTIONS}"` in the
recipe's `do_compile()` — see the comment there for why `oe_runmake -C
${S}/ta` needs this passed explicitly (unlike `xtest`'s own recipe, which
gets it for free via `EXTRA_OEMAKE`).

### `imx93-hello-ca`: `TEEC_OpenSession failed: 0x... origin 0x...`

`TEEC_Result` codes are somewhat generic; `err_origin` tells you which layer
actually rejected the call — decode it before guessing:

| `err_origin` | Layer that failed | Likely cause here |
|---|---|---|
| `0x1` `TEEC_ORIGIN_API` | `libteec` itself | Bad arguments from the CA side — check `main.c`'s `TEEC_PARAM_TYPES()` call matches the TA's expectation exactly |
| `0x2` `TEEC_ORIGIN_COMMS` | Kernel/transport | `/dev/tee0` issue — check `ls -l /dev/tee*` and `dmesg \| grep -i optee` |
| `0x3` `TEEC_ORIGIN_TEE` | OP-TEE core (S-EL1) | **Most common one you'll hit**: OP-TEE couldn't find/load the `.ta` — usually the `.ta` filename doesn't exactly match the UUID compiled into `imx93_hello_ta.h`, or the file isn't under `/lib/optee_armtz/` at all. `ls /lib/optee_armtz/` and compare the filename (minus `.ta`) against the UUID string byte-for-byte. |
| `0x4` `TEEC_ORIGIN_TRUSTED_APP` | The TA's own code | The TA loaded fine and rejected the call itself — e.g. `inc_value()`'s `TEE_ERROR_BAD_PARAMETERS` if `param_types` didn't match |

No error at all, but also no output? `tee-supplicant@teepriv0.service` may
not be running — check with `systemctl status tee-supplicant@teepriv0.service`
(see `../../Docs/optee-trustzone-hands-on.md` for why it's *not* a plain
`tee-supplicant.service` on this BSP).

---

## Quick checklist (copy/paste, on the board)

Every check from this doc, in the order to run them — stop at the first one
that looks wrong, it tells you which layer to focus on:

```bash
# 1. Driver + doorway devices
dmesg | grep -i optee
ls -l /dev/tee*

# 2. Supplicant alive (udev-instantiated, not a plain-named unit)
systemctl status tee-supplicant@teepriv0.service

# 3. The TA binary is present, named exactly as its own UUID
ls -l /lib/optee_armtz/

# 4. The actual end-to-end call
imx93-hello-ca
# expect: "Invoking TA to increment 42" / "TA incremented value to 43"
```

All four green → the full `svc → smc → S-EL1 → S-EL0` path this recipe
exists to demonstrate is confirmed working, end to end, on real hardware.
