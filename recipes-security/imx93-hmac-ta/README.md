# imx93-hmac-ta — build & test

A streaming HMAC-SHA256 OP-TEE Trusted Application for FRDM-IMX93, plus a
colorful, menu-driven Normal-World CLI client (`imx93-hmac-ca`) styled
after this layer's own `fota-bootloader` tool (same Red/Green/Yellow/Blue
palette, same numbered-menu-with-a-9-to-exit convention).

The TA implements exactly the 3-command streaming API this feature was
built around, mapped directly onto OP-TEE's own Crypto API:

| Command | OP-TEE API call | What it does |
|---|---|---|
| `HMAC_Clear` | `TEE_MACInit()` | Discard anything appended so far, start a fresh message with the same key |
| `HMAC_Append_Data` | `TEE_MACUpdate()` | Feed in one chunk (callable any number of times, any size) |
| `HMAC_Get_Final` | `TEE_CopyOperation()` + `TEE_MACComputeFinal()` | Return the digest of everything appended so far — **non-destructive checkpoint**, the running stream keeps going |

This is a genuinely **streaming** implementation — the CA can HMAC a
multi-gigabyte file by reading and appending it in 4 KiB chunks, without
ever holding more than one chunk in memory on either side of the world
boundary. See `files/ta/imx93_hmac_ta.c` for the fully-commented TA source,
and this layer's simpler `../imx93-hello-ta/` recipe first if you haven't
already — this one assumes that context.

**`HMAC_Get_Final` is a checkpoint, not a terminator.** It does *not* end
the stream: internally the TA clones the running operation's state with
`TEE_CopyOperation()` and finalizes the *clone* instead of the real one
(`TEE_MACComputeFinal()` is inherently one-way in the GP spec — there is
no "unfinalize" — so cloning first is the only way to peek at an
intermediate result without disturbing the original). This means you can
call `Get_Final`, keep calling `Append_Data`, and call `Get_Final` again —
the second result covers everything appended cumulatively, old and new
together. Only `HMAC_Clear` actually discards the running stream.

For the underlying TrustZone/OP-TEE concepts (worlds, `svc`/`smc`, why
`IMSG()` logs need a serial cable, the two-`.bbappend` log-level gotcha),
see [`../../Docs/optee-trustzone-hands-on.md`](../../Docs/optee-trustzone-hands-on.md).

---

## Key handling

`get_hmac_key()` in the TA implements exactly the "hardware key if it
exists, else a dummy key for testing" behavior this feature asked for,
using real GlobalPlatform TEE Internal API calls (not a shortcut):

1. **Try to open an existing persistent key object** in
   `TEE_STORAGE_PRIVATE`. Persistent objects are encrypted at rest by
   OP-TEE's secure storage subsystem, whose own protection key ultimately
   derives from this SoC's Hardware Unique Key — a TA can never read the
   HUK directly (GlobalPlatform deliberately doesn't expose it), but it
   *can* get a key whose confidentiality-at-rest depends on it. That's
   what "internal hw key" means in practice from inside a TA.
2. **First run**: no key exists yet → generate a real random 256-bit key
   and persist it, so every future session (even after a reboot) finds
   and reuses the *same* key rather than silently generating a new one.
3. **Secure storage unusable** on this board/config → fall back to a
   fixed key embedded directly in `imx93_hmac_ta.c`
   (`HMAC_DUMMY_KEY`) — clearly marked in the source as testing-only,
   zero confidentiality (anyone who reads the `.ta` file's disassembly, or
   this source file, has it).

The session-open log line tells you which path was taken (see
[Monitoring](#monitoring--verifying-which-key-path-was-used) below).

---

## Build + test

### Standalone build

```bash
cd ~/Data/Yocto/IMX93/frdm-imx93
bitbake imx93-hmac-ta
```

Outputs land at `tmp/work/armv8a-poky-linux/imx93-hmac-ta/1.0/image/`:
`usr/bin/imx93-hmac-ca` and `usr/lib/optee_armtz/<UUID>.ta`.

### Push to an already-running board (no reflash)

```bash
scp tmp/work/armv8a-poky-linux/imx93-hmac-ta/1.0/image/usr/bin/imx93-hmac-ca \
    root@192.168.1.101:/usr/bin/
scp tmp/work/armv8a-poky-linux/imx93-hmac-ta/1.0/image/usr/lib/optee_armtz/*.ta \
    root@192.168.1.101:/lib/optee_armtz/
```

### Run it

```bash
imx93-hmac-ca
```

Then, from the menu: try **option 1** with a real file path (e.g.
`/etc/hostname`), or **option 2** a few times with different text before
**option 4**, to see the streaming behavior for yourself — appending `"ab"`
in one call and appending `"a"` then `"b"` in two calls must (and will)
produce the identical digest.

### Ship it permanently

Already listed in `imx-image-sec-min.bb`'s `IMAGE_INSTALL`, next to
`imx93-hello-ta`. `bitbake imx-image-sec-min` and deploy as usual — see the
top-level repo README and `../imx93-hello-ta/README.md` Option B for the
full flow.

---

## Verifying it's actually working

**1. Correctness check — a known-answer HMAC.** HMAC-SHA256 test vectors
are widely published; since this TA's key is either a random
secure-storage key (path 1/2 above) or the fixed `HMAC_DUMMY_KEY` (path 3),
you can't check against a *public* HMAC test vector directly unless you
temporarily hardcode a known key. The practical check instead: run the
same input through option 1 (or 2+4) **twice in a row, without rebuilding
or rebooting in between** — the digest must be byte-for-byte identical
both times. Different digests for the same input on the same boot means
something is wrong with the streaming logic (state leaking between calls,
uninitialized memory, etc.) — open an issue with yourself before trusting
this TA further.

**2. Streaming equivalence check** — the property the whole design depends
on: HMAC of `"hello world"` appended in one call must equal HMAC of
`"hello "` then `"world"` appended in two calls. Use option 3 (clear),
option 2 twice with the two halves, option 4 — compare against option 1 on
a file containing `hello world` with no trailing newline (`printf 'hello world' > /tmp/t && `
then pick option 1, path `/tmp/t`). Both must match.

**3. Checkpoint (non-destructive `Get_Final`) check** — option 3 (clear),
option 2 with `"foo"`, option 4 (note the digest), option 2 with `"bar"`
(no clear in between), option 4 again. The second digest must equal
HMAC of `"foobar"` computed in one shot (option 1 on a file containing
exactly `foobar`) — **not** HMAC of `"bar"` alone. If it matches `"bar"`
alone instead, `TEE_CopyOperation()` isn't actually preserving state
correctly on this OP-TEE build — worth reporting upstream, this is
supposed to be a portable GP API guarantee.

**4. Session isolation** — open two SSH sessions, run `imx93-hmac-ca` in
both, start appending different data in each without finalizing. Each
should only ever see its own data in its own `Get_Final` result — this is
`struct hmac_session_ctx` in the TA doing its job (verified by code
inspection; per-session state, not shared globals).

---

## Monitoring / verifying which key path was used

Same rule as `imx93-hello-ta`: `IMSG()` output only ever reaches the
physical serial/UART console, never SSH/`dmesg`/`journalctl` — see
`../imx93-hello-ta/README.md`'s "why SSH can NEVER show this" section for
why, verified against this exact board's OP-TEE platform code.

With OP-TEE's log level raised (the two `.bbappend`s in
`recipes-security/optee/` already in this layer, see the sibling recipe's
README for the full rebuild+reflash steps) and watching a real serial
connection, opening a session with `imx93-hmac-ca` prints exactly one of:

```
I/TA: imx93-hmac-ta: no stored key yet -- generating one
I/TA: imx93-hmac-ta: generated + persisted a new secure-storage-backed key
I/TA: imx93-hmac-ta: session opened (key: secure-storage-backed)
```
on the **first** run ever on a given board/rootfs, then on every run after
that:
```
I/TA: imx93-hmac-ta: reusing existing secure-storage-backed key
I/TA: imx93-hmac-ta: session opened (key: secure-storage-backed)
```

If secure storage isn't usable on your build/config, you'll instead see:
```
I/TA: imx93-hmac-ta: WARNING -- falling back to the embedded dummy key (testing only, NOT secret -- see this file's own comment)
I/TA: imx93-hmac-ta: session opened (key: embedded dummy (testing))
```
every single time (no persistence attempted once storage has already
failed once per session) — this is expected and fine for testing per this
feature's own requirements, just don't rely on the HMAC's confidentiality
in that state.

---

## Troubleshooting

This recipe was built directly on top of `imx93-hello-ta`'s already-solved
problems (`TA_DEV_KIT_DIR` path, `user_ta_header_defines.h`,
`LIBGCC_LOCATE_CFLAGS`, the two-`.bbappend` log-level requirement) — see
`../imx93-hello-ta/README.md`'s own Troubleshooting section for all of
those in detail; they apply here identically. Additions specific to this
recipe:

### `TEEC_InvokeCommand failed: ... origin 0x4` on `HMAC_Get_Final`

`origin 0x4` (`TEEC_ORIGIN_TRUSTED_APP`) with `HMAC_Get_Final` almost
always means the output buffer the CA passed was too small — but
`imx93-hmac-ca` always sizes it to `TA_HMAC_DIGEST_SIZE` (32 bytes,
exactly right for HMAC-SHA256), so seeing this here likely means the
shared header (`files/ta/include/imx93_hmac_ta.h`) was edited
inconsistently between a rebuilt TA and a not-yet-rebuilt CA (or
vice versa) — rebuild **both** `ta/` and `host/` together, not just one.

### Every session logs the dummy-key fallback, never the secure-storage path

Means `TEE_OpenPersistentObject`/`TEE_CreatePersistentObject` are failing
with something other than "not found" on first run — check the *actual*
error code in the `EMSG()` line right above the fallback warning (raise
the log level and watch serial, per
[Monitoring](#monitoring--verifying-which-key-path-was-used) above) rather
than guessing; common real-world cause is `tee-supplicant` not running
(secure storage's REE-FS backend needs it) — see
`../imx93-hello-ta/README.md`'s own checklist for confirming
`tee-supplicant@teepriv0.service` is actually up.
