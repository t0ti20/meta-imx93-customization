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
The one-time `/etc/exports` registration (`ln -sfn` + `exportfs -ra`) is
printed, not run automatically, the first time the export is missing.

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
