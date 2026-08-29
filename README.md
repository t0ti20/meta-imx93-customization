# meta-imx93-customization

Local downstream customization layer for the FRDM-IMX93 board, on top of NXP's
i.MX Yocto BSP. This layer is registered directly in `bblayers.conf` (priority
20) — it is **not** part of the `repo` manifest, so `repo sync` never touches
it and never will overwrite anything here.

## What's in this layer

### Board fix: 2CS/2GB LPDDR4X DRAM support

`recipes-bsp/u-boot/u-boot-imx_2024.04.bbappend` backports NXP upstream commit
`4c35a6086aedca2f6220382920242ad81ae372f6` via
`0010-imx93_frdm-Add-2CS-2GB-DRAM-support.patch`. Without this, boards built
with the substituted 2CS/2GB DRAM chip hang during SPL DDR init. Confirmed
fixed on real hardware (SPL → BL31 → U-Boot → Linux → systemd boots cleanly
across repeated cycles).

### Board feature: network image download-and-flash (`netflash`)

`recipes-bsp/u-boot/u-boot-imx/0020-imx93_frdm-Add-network-image-flash.patch`
adds an opt-in U-Boot env command, `netflash`, that fetches a full disk
image over TFTP from a fixed server and raw-writes it to the SD card
(`mmc dev 1`), starting at sector 0 — matching this board's `.wks` layout
where `imx-boot`, the FAT `/boot` partition, and the ext4 rootfs are all
packed into one image file.

**This does NOT run automatically, and not on every boot.** Powering the
board on and doing nothing still boots exactly as before — U-Boot's default
autoboot (`CONFIG_BOOTCOMMAND` / `bsp_bootcmd`) is completely untouched by
this patch, so it loads the kernel from the SD card and boots Linux the same
way it always did. `netflash` only ever runs if a human interrupts autoboot
at the serial console and types `run netflash` by hand. It's a one-shot,
manual recovery/provisioning action (like re-imaging a card with `dd` from a
PC, just over the network instead) — not a step in the normal boot chain,
and there is nothing in this patch that would make it repeat or persist
across boots on its own.

Defaults baked in by the patch (all overridable at the U-Boot prompt with
`setenv`, without rebuilding):
- Board static IP: `ipaddr=192.168.1.101`, `netmask=255.255.255.0`
- Server: `serverip=192.168.1.100`
- File: `netflash_gz_file=imx-image-sec-min-imx93frdm.rootfs.wic.gz`
- Scratch buffers: `netflash_comp_addr=0xA0000000` (compressed download),
  `netflash_img_addr=0xB0000000` (decompressed image) — chosen well clear of
  `kernel_addr_r`/`fdt_addr_r`/`splashimage`/`cntr_addr` and comfortably
  within the board's 2GB DRAM.

**Transfer format is gzip, not zstd.** Yocto's default `IMAGE_FSTYPES` for
this machine produce `.wic.zst`, but this U-Boot build has no exposed zstd
CLI command (`cmd/unzip.c`/`cmd/zip.c` exist for gzip; `lib/zstd/*` is
internal-only, used for FIT images). `imx-image-sec-min.bb` adds
`IMAGE_FSTYPES += "wic.gz"` so bitbake produces the matching
`imx-image-sec-min-imx93frdm.rootfs.wic.gz` directly — no manual host-side
recompression needed. Copy that file to your TFTP server's root directory.

**Usage**: at the U-Boot prompt (interrupt autoboot), run:
```
run netflash
```
This only proceeds to `mmc write` if both the TFTP download and the gzip
decompression report success — a failed/interrupted download leaves the SD
card untouched, so a bad transfer doesn't leave the board half-flashed.
Every stage prints a `********…********` banner tagged `[FLASH]`
(fetching, download OK/decompressing, writing to SD, done, or either
failure) — same visual style as the `[BOOT SOURCE]` banners used
elsewhere in this layer, so the serial console makes each step
unambiguous.

**Risk**: `netflash` performs a raw write to the same SD card (`mmc dev 1`)
the board may currently be running from. Interrupting power mid-write can
still corrupt the card even with the download/decompress guard above (the
guard only protects against a *failed transfer*, not a power loss during
the write itself). Test against a spare/scratch SD card before relying on
this against a card in active use.

This is purely additive — `CONFIG_BOOTCOMMAND` and the existing
`bsp_bootcmd`/`netboot` scripts are untouched, so normal autoboot behavior
is unchanged. `imx-image-sec-full.bb` `require`s `imx-image-sec-min.bb`, so
it inherits `IMAGE_FSTYPES += "wic.gz"` too — the same mechanism works for
both images out of the box (`netflash_gz_file` only needs a `setenv` if you
want to flash `sec-full` instead of the baked-in `sec-min` default).

### Board feature: network-first boot, static IP (`net_first_bootcmd`)

`recipes-bsp/u-boot/u-boot-imx/0030-imx93_frdm-Add-network-first-boot-with-static-IP.patch`
changes the board's *default, no-interaction* boot policy: on every normal
power-on, it now tries a TFTP+NFS network boot first, and only falls back to
the on-board SD card if that fails — the reverse of the stock priority
(SD/eMMC/USB first, network only as `bsp_bootcmd`'s last resort). Three
changes, all in `imx93_11x11_frdm_defconfig` / `imx93_frdm.h`:

- **`CONFIG_BOOTDELAY=3`** — was `0`. Previously "Hit any key to stop
  autoboot" gave a literal zero-second window; there was no way to actually
  interrupt autoboot by hand. Now there's a real 3-second window.
- **`CONFIG_BOOTCOMMAND`** gains a new first step: `run sr_ir_v2_cmd;run
  net_first_bootcmd;run distro_bootcmd;run bsp_bootcmd` (was `...;run
  distro_bootcmd;run bsp_bootcmd`). `distro_bootcmd`/`bsp_bootcmd` — the
  existing SD/eMMC/USB boot chain — are **not modified at all**; they still
  run exactly as before whenever `net_first_bootcmd` doesn't boot anything.
- **New `net_first_bootcmd` env script** (in `imx93_frdm.h`, alongside the
  existing `NETFLASH_ENV` block): sets static `ipaddr=192.168.1.101` /
  `netmask=255.255.255.0` / `gatewayip=192.168.1.1` / `serverip=192.168.1.100`
  (no DHCP anywhere in this path), attempts `tftpboot` of `imx93/Image` then
  `imx93/imx93-11x11-frdm.dtb`, and on success mounts root over NFS
  **read-write** (`nfsroot=...,v3,tcp,rw` — unlike the older `netboot`/
  `netargs` pair below, which is untouched and still mounts read-only) before
  calling `booti` directly. `netretry=no` / `autoload=no` keep a
  missing/unreachable TFTP server from stalling boot in a long retry storm —
  one failed attempt and it falls straight through to `distro_bootcmd`/
  `bsp_bootcmd` (SD card) instead.

**Boot-source banners, everywhere**: this patch also replaces the single
plain status lines the *existing*, untouched `mmcboot`/`netboot`/
`bsp_bootcmd` scripts used to print (`"Booting from mmc ..."`, `"Booting
from net ..."`, `"Running BSP bootcmd ..."`) with the same
`********…********` banner style, tagged `[BOOT SOURCE]`, that
`net_first_bootcmd` uses. Only the echo lines changed — the actual control
flow of `mmcboot`/`netboot`/`bsp_bootcmd` is untouched. Every real
boot-path decision anywhere in this BSP now prints a matching banner:
trying network (static), network OK / network failed + falling back,
trying internal SD card, booting from internal SD card, booting from
network (old DHCP path, if ever manually invoked or reached via
`bsp_bootcmd`'s own fallback). Read the serial console and it's unambiguous
which of the three boot paths actually ran and what it decided, without
reading the U-Boot environment definitions.
`netflash` (the flashing command, not a boot path) got the same treatment
in its own patch — see `[FLASH]`-tagged banners below.

**This is a real firmware behavior change**, not just an env default — it
needs a `u-boot-imx` rebuild (`CONFIG_BOOTDELAY`/`CONFIG_BOOTCOMMAND` are
Kconfig values, baked into the compiled `imx-boot`) and a re-flash of just
the bootloader via `--flash-boot` (see below) to take effect on
already-provisioned hardware. A card already flashed with a full image via
`netflash` is unaffected either way whenever the network path is
unavailable — it still boots from SD exactly as it always did, since
`distro_bootcmd`/`bsp_bootcmd`/`mmcboot` are untouched.

Note there are now **two independent network-boot paths** in this BSP,
intentionally not merged:
- `net_first_bootcmd` (new, above) — automatic, static IP, `imx93/`-prefixed
  TFTP paths, read-write NFS root.
- `netboot` (existing, from meta-imx-frdm, unmodified) — manual-only unless
  `bsp_bootcmd` falls all the way through to it, DHCP, read-only NFS root,
  generic (non-`imx93/`-prefixed) TFTP paths. Still reachable by typing `run
  netboot` yourself, e.g. if you want the DHCP/read-only behavior for some
  reason, or by `bsp_bootcmd`'s own internal fallback if *both* the network
  and the SD card fail for `net_first_bootcmd`/`bsp_bootcmd` respectively.

### Deploying to this host's TFTP/NFS servers: `scripts/deploy-to-network.sh`

This host already runs `tftpd-hpa` (root `/home/khaled/Documents/Network/TFTP`,
shared with other boards' netboot setups, e.g. the RPi4) and
`nfs-kernel-server` (existing export `/exports/raspi4`). The script copies a
freshly built image's artifacts into both, for two independent, opt-in
U-Boot workflows — nothing here touches `CONFIG_BOOTCOMMAND` or autoboot:

- **`run netflash`** (flash): needs the `.wic.gz` in the TFTP root. The
  script copies it there under its real name, matching this layer's baked-in
  `netflash_gz_file` default with no `setenv` needed for `sec-min`.
- **`run netboot`** (live boot, no flashing — built into meta-imx-frdm's
  board support, `root=/dev/nfs`): needs the kernel `Image` + device tree
  over TFTP, and the rootfs over NFS. The script copies `Image` and
  `imx93-11x11-frdm.dtb` under `TFTP_DIR/imx93/` (**not** the TFTP root —
  other boards' netboot setups already use the generic name `Image` there,
  so a shared top-level copy would clobber theirs), and extracts the
  image's `.tar.zst` rootfs into a dedicated NFS export directory
  (`/home/khaled/Documents/Network/NFS-IMX93` by default, exported as
  `/exports/imx93`, mirroring the existing `/exports/raspi4` pattern).
  Since `fdtfile`/`image` are shared U-Boot variables also used by the
  normal `mmcboot` path, point them at the board only for the netboot
  session itself, not permanently:
  ```
  setenv image imx93/Image
  setenv fdtfile imx93/imx93-11x11-frdm.dtb
  setenv serverip 192.168.1.100
  setenv nfsroot /exports/imx93
  run netboot
  ```
  (Don't `saveenv` after this unless you want net-boot-by-default — a fresh
  power cycle reloads the compiled-in defaults either way, so skipping
  `saveenv` keeps normal SD-card autoboot as the default.)

**Usage**:
```
scripts/deploy-to-network.sh sec-min            # both TFTP + NFS (default image)
scripts/deploy-to-network.sh sec-full --tftp-only
scripts/deploy-to-network.sh --nfs-only
```
Reads artifacts from `tmp/deploy/images/imx93frdm/` (override via
`DEPLOY_DIR`/`TFTP_DIR`/`NFS_DIR` env vars) — build the image first with
`bitbake`. The NFS extraction runs `sudo rm -rf`+`tar -xp` on the export
directory to preserve device nodes/permissions from the rootfs, so it will
prompt for a `sudo` password; the script refuses to run against `NFS_DIR`
values of `/`, `/home`, or `/home/khaled` as a guard against a bad override.

#### First-time bootstrap: `--flash-boot` (erase + bootloader only, no image)

For a blank (or previously-used) SD card, there's no need to `dd` a full
`.wic` image just to get the board alive — a first boot only needs the
bootloader; the kernel and rootfs come from `net_first_bootcmd`/`netboot`/
`netflash` afterward. `--flash-boot`:

1. **Erases every existing partition** on the card — unmounts anything the
   host auto-mounted from it, `wipefs -a` (kills partition-table/filesystem
   signatures), then zeroes the first 8MiB (MBR + the whole `imx-boot`/env
   gap before `/boot`, including the env's `CONFIG_ENV_OFFSET=0x700000`) and
   the last 1MiB (in case of a stray GPT backup header). This exists because
   a card with old partitions left in place was observed getting one of them
   silently auto-mounted **read-write** by the booted OS during an NFS-root
   session — wiping first removes that landmine, and guarantees a fresh
   (not stale-and-invalid) U-Boot environment on next boot.
2. Writes *only* `imx-boot` (the combined SPL+ATF+OP-TEE+U-Boot-proper
   container, machine-level — the same file regardless of which image
   recipe you've built) at byte offset 32KiB.

```
scripts/deploy-to-network.sh --flash-boot /dev/sdX
```

That offset comes straight from this board's own `.wks` layout (`part
u-boot --source rawcopy --sourceparams="file=imx-boot" ... --align 32`,
i.e. `dd bs=1K seek=32`) — the same place `imx-boot` lands inside a full
`.wic` image, just written on its own with no partition table, no `/boot`,
no rootfs after it. With the network-first boot patch above, the board now
tries the network automatically on every power-on and only reaches the
U-Boot prompt if that fails too (e.g. no TFTP server reachable) — either
way, nothing else needs to be on the card for it to come up.

Safety: the script only accepts a block device path (`-b` check), refuses
to target whatever disk backs the host's own root filesystem (checked via
`findmnt`/`lsblk`), prints the target's `lsblk` output, and requires typing
`YES` before it wipes/writes anything — there's no way to trigger it
non-interactively or by accident. Still, this **unconditionally destroys all
data** on the target device, and a wrong `/dev/sdX` is unrecoverable, so
double-check the device node (`lsblk` before running) every time, especially
on a machine where drive letters can shift between reboots.
The one-time `/etc/exports` registration (`ln -sfn` + `exportfs -ra`) is
printed, not run automatically, the first time the export is missing.

### Welcome banner: `classes/imx93-welcome-banner.bbclass`

Both image recipes (`imx-image-sec-full` picks it up automatically via its
`require imx-image-sec-min.bb`) inherit this class, which writes a
build-stamped banner to `/etc/issue` (shown on the serial console the
moment boot reaches the login prompt — no login needed) and `/etc/motd`
(shown again after logging in), in the same `********…********` box style
used by this layer's U-Boot boot/flash banners:

```
********************************************************
*  [IMX93-CUSTOM] NXP i.MX93 FRDM Security Testing Image
********************************************************
*  Image      : imx-image-sec-min
*  Machine    : imx93frdm
*  Distro     : fsl-imx-xwayland 6.6-scarthgap
*  Built      : 2026-08-29 15:42:10
*  Builder    : Ather
********************************************************

imx93frdm login:
```

`Image` (`${PN}`), `Machine`, and `Distro`/`Distro version` come straight
from the recipe/build config, so `sec-min` vs `sec-full` and whatever
`DISTRO`/`MACHINE` a given build used are always correct without manual
upkeep. `Built` is a `time.strftime` snapshot taken when bitbake parses the
class (i.e. this build's start time, same convention as the stock
`DATE`/`TIME` bitbake variables). `Builder` defaults to `Ather`
(`IMX93_BUILDER`, overridable per build — e.g. `IMX93_BUILDER = "someone
else"` in `local.conf` — if someone else ever produces a build from this
layer) so a given card/image can always be traced back to who built it and
when, at a glance, before even logging in.

The original `/etc/issue`'s `\n \l` escape line (agetty-substituted
hostname/tty) is preserved at the bottom of the new banner, so the
usual "log in on this tty as this host" info isn't lost — only the plain
one-line NXP branding above it is replaced.

### Image recipes: `recipes-fsl/images/`

Two custom images for hands-on security learning/testing on this board, both
headless (no graphics, no Weston/X11), no SELinux, no machine learning:

| Image | Compressed size | Use case |
|---|---|---|
| `imx-image-sec-min` | ~151 MB | Small, fast-building baseline: SSH, Python3, WiFi/Ethernet, AHAB/ELE/OP-TEE/TPM2 |
| `imx-image-sec-full` | larger, longer build | Everything in `sec-min` plus CAN bus, HSM/PKCS11, and a broad security-testing tool suite |

For comparison, NXP's own `imx-image-full` is ~951 MB compressed and includes
Weston/Wayland, GStreamer, OpenCV, Qt6, machine learning (TensorFlow
Lite/ONNX/ArmNN), and full SDK/profiling tooling — none of which are needed
for security work on a headless board, so both custom images drop all of it.

#### `imx-image-sec-min`

Baseline install:
- **Core**: `packagegroup-core-boot`, `kernel-modules`, `util-linux`,
  `coreutils`, filesystem/storage tools (`e2fsprogs-mke2fs/resize2fs`,
  `mmc-utils`, `mtd-utils`, `u-boot-fw-utils`)
- **Python**: `python3`, `python3-pip`, `python3-cryptography`
- **Networking**: `ethtool`, `net-tools`, `iproute2`, `iptables`, `tcpdump`,
  `bridge-utils`, `wpa-supplicant`, `hostapd`, `wireless-tools`, NXP WiFi
  SDK/firmware (`nxp-wlan-sdk`, `firmware-nxp-wifi-nxpiw610/612-sdio`)
- **Board security**: `packagegroup-imx-security` (ELE/EdgeLock crypto:
  `openssl-provider-se050`, `plug-and-trust-ecc`), `packagegroup-fsl-optee-imx`
  (OP-TEE OS/client/test), `packagegroup-security-tpm2` (`tpm2-tools`,
  `tpm2-tss`, `tpm2-abrmd`, `tpm2-pkcs11`, `tpm2-openssl`,
  `python3-tpm2-pytss`, plus `libtss2-tcti-mssim` — the simulator TCTI, so the
  TPM2 stack is usable via a software TPM (`swtpm`) even without a physical
  TPM chip on this board), `openssl`
- **Debug/admin**: `strace`, `gdb`, `vim`, `htop`, SSH server
  (`ssh-server-openssh`)

**Root login is passwordless** (Yocto's default `debug-tweaks` image feature
is left enabled) — log in on serial console or SSH as `root` with no
password. This is deliberate for a hands-on testing image, not an oversight;
if you want a real password gate instead (e.g. before exposing the board's
SSH server to an untrusted network), remove `debug-tweaks` and add an
`extrausers`-based hash in `imx-image-sec-min.bb` — see the [Yocto
`extrausers` class
docs](https://docs.yoctoproject.org/ref-manual/classes.html#extrausers-bbclass)
for the exact syntax.

#### `imx-image-sec-full`

`require imx-image-sec-min.bb`, then adds:

- **CAN bus**: `can-utils` (SocketCAN candump/cansend/cangen/cansniffer).
  The kernel already builds `CONFIG_CAN=m` / `CONFIG_CAN_FLEXCAN=m` as
  modules — this just adds the userspace tools.
- **HSM / PKCS#11**: `softhsm` (software HSM, PKCS#11 token), `opensc`
  (`pkcs11-tool` and smartcard/token utilities), `pkcs11-provider` (OpenSSL 3
  provider), `libp11` (legacy `engine_pkcs11` OpenSSL engine),
  `packagegroup-security-parsec` (Parsec security abstraction daemon),
  `swtpm` (software TPM, usable via the TPM2 simulator TCTI above)
- **WiFi/network security testing**: `aircrack-ng` (WiFi auditing suite),
  `ncrack` (network auth cracking, pentest practice), `suricata` (network
  IDS/IPS, works well alongside the `tcpdump` already in `sec-min`),
  `arpwatch` (ARP spoofing/monitoring), `sshguard` (SSH brute-force
  protection)
- **Host security / compliance**: `checksec` (binary hardening checks —
  NX/PIE/RELRO/stack canaries), `aide` (file integrity monitoring),
  `openscap` + `scap-security-guide` (security compliance scanning against
  real benchmarks), `clamav` (antivirus — the heaviest single addition here,
  both in build time and runtime storage for its signature database)
- **Encryption / auth hardening**: `fscrypt` + `fscryptctl` (ext4 native
  filesystem encryption), `ecryptfs-utils` (encrypted directories),
  `cryptmount` (dm-crypt frontend), `paxctl` (exploit-mitigation flag
  inspection — mostly educational without a PaX-patched kernel),
  `google-authenticator-libpam` (TOTP two-factor auth via PAM — pairs with
  the SSH server already in `sec-min` for a hands-on 2FA lab)

**Explicitly left out, and why:**
- `chipsec` — x86_64/i686-only (Intel chipset security tool), architecturally
  incompatible with aarch64/i.MX93.
- `smack`, `apparmor` — alternate Mandatory Access Control frameworks. Like
  SELinux, these require their own `DISTRO_FEATURES` and are a distinct
  architectural decision, not silently bundled in here.
- `tripwire`, `ossec-hids`, `samhain`, `crowdsec` — overlap with
  `aide`/`openscap` for host integrity/IDS; skipped to avoid redundant heavy
  daemons. Easy to add on request.
- `krill`, `opendnssec`, `glome`, `libest`, `isic` — niche
  RPKI/DNSSEC/packet-fuzzing tooling, out of scope unless specifically asked
  for.
- **SELinux** — not part of this NXP BSP at all (no layer, no kernel config).
  Adding it is a separate, larger change (new external layer, kernel config
  fragment, `DISTRO_FEATURES` change, and real risk of a boot/login-breaking
  policy on a board that's never run it before) — tracked separately, not
  bundled into either image.
- **AVB (Android Verified Boot)** — doesn't exist anywhere in this Linux BSP;
  it's AOSP-specific. **AHAB** (i.MX93's actual secure-boot mechanism, via
  `cst`/`srktool` from the `imx-cst` recipe) is the real equivalent, but
  signing/closing the device is a separate, irreversible (OTP fuse-burning)
  action — not performed by any build here.
- `lynis`, `chkrootkit` — dropped, not by design but by network reality:
  their upstream source hosts (`downloads.cisofy.com`,
  `archive.ubuntu.com`) are unreachable from this build network (confirmed
  with the build sandbox fully disabled, and via Yocto's own
  `SOURCE_MIRROR_URL` fallbacks — all returned 404/DNS failure). If you have
  network access to those hosts elsewhere, drop the matching tarball into
  `DL_DIR` (`downloads/`) by hand and re-add the package name to
  `imx-image-sec-full.bb`'s `IMAGE_INSTALL`; the recipes themselves are
  otherwise unmodified in `meta-security`.

### Recipe fix: `fscrypt` SRCREV bump

`meta-security`'s `fscrypt_1.1.0.bb` pins a commit
(`7c80c73c084ce9ea49a03b814dac7a82fd7b4c23`) that no longer exists on
upstream's `master` branch — history was rewritten/rebased at some point
after that recipe was written. `git ls-remote` (against the allowed
`github.com` host) confirmed current `master` HEAD is
`ed08dee50fa7d906c6539bba8fa24e14aee6e516`; `recipes-security/fscrypt/fscrypt_1.1.0.bbappend`
in this layer bumps `SRCREV` to that commit. This is a local, layer-level fix
— `meta-security` itself is untouched.

### Extra layer registration

`imx-image-sec-full` needed `meta-security`'s top-level layer (collection
name `security`, priority 8) added to `bblayers.conf` — previously only its
`meta-parsec` and `meta-tpm` sub-layers were registered. The code was already
on disk (as the parent directory of those two sub-layers); this only adds a
`BBLAYERS +=` line, no new fetch, no `repo sync`.

## Building

No `bblayers.conf`/manifest edits are needed beyond what's already checked
into this repo — both this layer and `meta-security` are already registered.
Standard NXP setup flow:

```
cd /data/wksp/IMX93
source setup-environment frdm-imx93
bitbake imx-image-sec-min
# or
bitbake imx-image-sec-full
```

(Equivalent to running `imx-frdm-setup.sh` fresh, but re-uses the existing
build directory instead of re-generating `conf/`, which has previously been
observed to silently regenerate/corrupt `bblayers.conf` and drop custom layer
registration — prefer `source setup-environment frdm-imx93` for this reason.)

Output artifacts land in
`tmp/deploy/images/imx93frdm/imx-image-<name>-imx93frdm.rootfs.wic.zst`
(+ matching `.wic.bmap`), flashed to SD card the same way as
`imx-image-full`:

```
sudo bmaptool copy imx-image-<name>-imx93frdm.rootfs.wic.zst /dev/sdX
```
