# i.MX Yocto Project User's Guide

Personal reference copy, distilled from NXP document **UG10164**
(*Rev. LF6.18.20_2.0.0 — 25 June 2026*), source text at
`/home/khaled/Desktop/IMX93/Documents/UG10164.txt`.

This is the main NXP-side reference for how the Yocto BSP this board (FRDM-IMX93)
is built from actually works — layers, machine/distro selection, bitbake usage,
U-Boot configs, image deployment, and customization mechanics. It complements,
rather than replaces, this repo's own [`../../README.md`](../../README.md),
which documents what `meta-imx93-customization` itself adds on top of the stock
BSP described here.

> Page headers/footers ("UG10164", "User guide", revision/copyright lines, page
> numbers) present in every page of the source PDF-to-text dump have been
> stripped throughout; content is otherwise kept faithful to the source,
> reorganized under normal Markdown headings.

---

## Quick orientation for this board

- NXP's official machine name for this board in this release is
  **`imx93-11x11-lpddr4x-frdm`** (see [§5.1](#51-build-configurations)). This
  layer's own build (`source setup-environment frdm-imx93`, see the repo
  README) resolves to `MACHINE=imx93frdm` — a meta-imx-frdm-provided alias for
  the same hardware. If a stock NXP command in this guide references
  `imx93-11x11-lpddr4x-frdm` and it doesn't resolve in this build tree, try
  `imx93frdm` instead, or check `sources/meta-imx-frdm/conf/machine/`.
- Default distro for this board's build is `fsl-imx-xwayland` (Wayland + X11
  compat) — matches this guide's project-wide default when no `DISTRO` is
  given ([§5.1](#51-build-configurations)).
- U-Boot config for this machine: **`sd ecc`** — see
  [§5.5](#55-u-boot-configuration).
- The two custom images this layer builds (`imx-image-sec-min`,
  `imx-image-sec-full`) are headless equivalents of the stock
  `imx-image-multimedia`/`imx-image-full` described in
  [§5.2](#52-choosing-an-imx-yocto-project-image) — see this repo's own README
  for why graphics/ML were dropped.
- Relevant reference docs for this board mentioned throughout this guide (all
  external NXP documents, not included here):
  - **i.MX Linux User's Guide (UG10163)** — U-Boot/Linux install, boot
    switches, SD card prep, standalone kernel/U-Boot builds, Jailhouse detail.
  - **i.MX Porting Guide (UG10165)** — porting the BSP to a new/custom board.
  - **FRDM i.MX 93 Development Board Quick Start Guide (FRDM-IMX93)**.
  - **i.MX Linux Release Notes (RN00210)** — which SoCs/boards are validated
    per release.

---

## 1. Overview

This document describes how to build an image for an i.MX board using a Yocto
Project build environment: the i.MX release layer and i.MX-specific usage. The
Yocto Project itself is a Linux Foundation open-source collaboration for
embedded Linux development (yoctoproject.org); for vanilla Yocto without the
i.MX layer, follow the *Yocto Project Quick Start*.

The **FSL Yocto Project Community BSP** is a community effort (outside NXP)
supporting i.MX boards in Yocto. NXP's own **i.MX Yocto Project BSP** releases
an official collection of layers on top of that community BSP, providing
Board Support Package (BSP), middleware, firmware, and feature extensions for
the i.MX 6 → i.MX 9 family.

### Layer stack

**i.MX BSP Release layer — `meta-imx`** (sits on top of the community layers,
provides release-validated recipes/board configs/kernel+bootloader updates
for i.MX 6 → i.MX 9):

| Sub-layer | Purpose |
|---|---|
| `meta-imx-bsp` | Primary BSP: kernel, U-Boot, firmware, multimedia, GPU, VPU, security, board support |
| `meta-imx-sdk` | NXP distro modifications and SDK generation |
| `meta-imx-ml` | Machine-learning frameworks, demos, accelerators |
| `meta-imx-v2x` | V2X (Vehicle-to-Everything), mainly i.MX 8DXL |
| `meta-imx-cockpit` | Digital cockpit / graphics / HMI, i.MX 8QuadMax |

**Yocto Project community layers:**

| Layer | Purpose |
|---|---|
| `meta-freescale` | Base + i.MX Arm reference board support |
| `meta-freescale-distro` | Extra dev/demo capability items |
| `meta-freescale-3rdparty` | Third-party / partner board support |
| `fsl-community-bsp-base` (often renamed `base`) | Base FSL Community BSP config |
| `meta-openembedded` | OE-core universe collection (layers.openembedded.org) |
| `meta-yocto` | Basic Yocto items in Poky |
| `meta-browser` | Browsers |
| `meta-qt6` | Qt 6 |
| `meta-timesys` | Vigiles CVE monitoring/notification |

`meta-imx` is public at <https://github.com/nxp-imx/meta-imx>; it releases
recipes/machine configs not yet upstreamed into `meta-freescale`/
`meta-freescale-distro`. The whole BSP is assembled via an XML manifest at
<https://github.com/nxp-imx/imx-manifest> (see [§4](#4-yocto-project-setup)).

Most component source is public under the `nxp-imx` GitHub org (kernel,
U-Boot). Some components are instead distributed as prebuilt packages via the
**i.MX mirror**, pulled directly by their recipes rather than from GitHub.

Current release: **LF6.18.20_2.0.0**, based on **Yocto Project 6.0
("Wrynose")**. Release-validated recipes get upstreamed into
`meta-freescale`/`meta-freescale-distro` for the following Yocto release.

### 1.1 End-user licence agreement (EULA)

`imx-setup-release.sh` displays the NXP EULA during setup. Accepting it is
required to let the build untar proprietary packages from the i.MX mirror; the
acceptance is then persisted per build directory (`ACCEPT_FSL_EULA = "1"` in
that directory's `local.conf`) and not asked again for that directory.

### 1.2 References

i.MX SoC families covered by this BSP (see RN00210 for exactly which SoCs are
validated in a given release — older ones may still build but aren't
necessarily validated at the current level):

- **i.MX 6**: 6QuadPlus, 6Quad, 6DualLite, 6SoloX, 6SLL, 6UltraLite, 6ULL, 6ULZ
- **i.MX 7**: 7Dual, 7ULP
- **i.MX 8**: 8QuadMax, 8QuadPlus, 8ULP
- **i.MX 8M**: 8M Plus, 8M Quad, 8M Mini, 8M Nano
- **i.MX 8X**: 8QuadXPlus, 8DXL, 8DualX
- **i.MX 9**: i.MX 91, **i.MX 93**, i.MX 93W, i.MX 95, i.MX 952, i.MX 943

**Companion NXP documents:**

| Doc ID | Title | Covers |
|---|---|---|
| RN00210 | i.MX Linux Release Notes | Release info |
| UG10163 | i.MX Linux User's Guide | U-Boot/Linux install, i.MX-specific features |
| **UG10164** | **i.MX Yocto Project User's Guide** | **This document** |
| UG10165 | i.MX Porting Guide | Porting BSP to a new board |
| UG10166 | i.MX Machine Learning User's Guide | ML info |
| UG10167 | i.MX DSP User's Guide | DSP for i.MX 8 |
| UG10168 | i.MX 8M Plus Camera and Display Guide | ISP sensor interface API |
| UG10169 | i.MX Digital Cockpit HW Partitioning (8QuadMax) | Cockpit HW solution |
| UG10159 | i.MX Graphics User's Guide | Graphics features |
| RM00293 | i.MX Linux Reference Manual | Linux driver info |
| RM00294 | i.MX VPU API Linux Reference Manual | VPU API (i.MX 6) |
| RM00284 | EdgeLock Enclave HSM API | ELE API (8ULP, 93, 95) |
| UG10215 | i.MX 95 Camera Porting Guide | RAW Bayer sensor porting on i.MX 95 |

**Quick Start Guides** (per-board, on nxp.com), including the FRDM boards:
IMX6QSDPQSG, IMX6ULTRALITEQSG, IMX6ULLQSG, SABRESDBIMX7DUALQSG,
IMX8MQUADEVKQSG, 8MMINIEVKQSG, 8MNANOEVKQSG, IMX8QUADXPLUSQSG,
IMX8QUADMAXQSG, IMX8MPLUSQSG, IMX8ULPQSG, IMX8ULPEVK9QSG, IMX93EVKQSG,
93QSBQSG, **FRDM-IMX93**, FRDM-IMX8MPLUS, FRDM-IMX91, FRDM-IMX91S, FRDM-IMX95.

Per-SoC landing pages: nxp.com/iMX6series, /imxSABRE, /iMX6UL, /iMX6ULL,
/imx6ulz, /iMX7D, /imx7ulp, /imx8, /imx91, **/imx93**, /IMX93W, /imx95,
/imx952, /imx94 (943).

---

## 2. Features

- **Linux kernel recipe** — `recipes-kernel/`; integrates `linux-imx.git` from
  the i.MX GitHub, fetched automatically by the recipe. Current release:
  **LF6.18.20_2.0.0**.
- **U-Boot recipe** — `recipes-bsp/`; integrates `uboot-imx.git`. This release
  uses an updated **v2026.04** i.MX U-Boot (not updated for every piece of
  hardware). The Community BSP's `u-boot-fslc` (mainline-based) is only
  community-supported, not supported against the L6.18.20 kernel. U-Boot
  versions in `meta-freescale` change frequently as i.MX updates land.
- **Graphics recipes** — `recipes-graphics/`.
  - Vivante GPU SoCs: `imx-gpu-viv` packages FB, XWayland, Wayland backend,
    Weston, per distro. Only i.MX 6 and i.MX 7 support framebuffer.
  - Mali GPU SoCs (**i.MX 9 only**): `mali-imx` packages XWayland/Wayland.
  - `xorg-driver` integrates `xserver-xorg`.
- **i.MX package recipes** — `firmware-imx`, `firmware-upower`,
  `imx-sc-firmware`, etc. in `recipes-bsp`, pulled from the i.MX mirror.
- **Multimedia recipes** — `recipes-multimedia/`. Proprietary (`imx-codec`,
  `imx-parser`) pull from the i.MX mirror; open-source ones pull from public
  GitHub. Some license-restricted codecs aren't on the public mirror —
  contact an i.MX Marketing rep to acquire them.
- **Core recipes** — policy/customization updates (e.g. udev rules);
  typically only touched when a release needs it.
- **Demo recipes** — `meta-imx/meta-imx-sdk`: image recipes + customization
  demos (touch calibration, demo apps).
- **Machine learning recipes** — `meta-imx-ml`: `tensorflow-lite`,
  `onnxruntime`, etc.
- **Cockpit recipes** — `meta-imx-cockpit`, `imx-8qm-cockpit-mek` machine only.
- **GoPoint recipes** — `meta-nxp-demo-experience`; bundled in all released
  full images.

---

## 3. Host Setup

Minimum host disk space (Ubuntu): **~50 GB** minimum, **120 GB** recommended
(enough for all backends), **250 GB** for machine-learning builds. Recommended
minimum host OS: **Ubuntu 22.04+**.

### 3.1 Docker

`imx-docker` provides docker setup scripts for a containerized host build
environment (follow its own README). Separately, `meta-virtualization`
(i.MX 8 only) enables **on-board** Docker — a headless system that can pull
containers from external Docker hubs.

### 3.2 Host packages

Yocto's own Quick Start lists the exact host-package set to check for your
distro. Essential packages for this BSP:

```
sudo apt-get install build-essential chrpath cpio debianutils diffstat file gawk \
    gcc git iputils-ping libacl1 libcrypt-dev locales python3 python3-git \
    python3-jinja2 python3-pexpect python3-pip python3-subunit socat texinfo \
    unzip wget xz-utils zstd efitools
```

The build uses whatever `grep` is default on `$PATH`; a non-standard `grep`
override elsewhere in `$PATH` can break builds — rename it if that happens.

### 3.3 Setting up the Repo utility

`repo` (built on Git) manages the many-repository layer structure. Yocto's
layered design suits this well.

```
mkdir ~/bin                       # if it doesn't already exist
curl https://storage.googleapis.com/git-repo-downloads/repo > ~/bin/repo
chmod a+x ~/bin/repo
```

Add to `.bashrc` (or `.config.fish` equivalent on this host's fish shell):

```
export PATH=~/bin:$PATH
```

---

## 4. Yocto Project Setup

The i.MX Yocto BSP release directory has a `sources/` directory (all layer
recipes, from both community and i.MX releases) plus setup scripts.

```
mkdir imx-yocto-bsp
cd imx-yocto-bsp
repo init -u https://github.com/nxp-imx/imx-manifest \
    -b imx-linux-wrynose -m imx-6.18.20-2.0.0.xml
repo sync
```

(`imx-yocto-bsp` is just an example directory name.) The full list of
manifest files for this release is at
<https://github.com/nxp-imx/imx-manifest/tree/imx-linux-wrynose>. After
`repo sync`, the BSP lands in `imx-yocto-bsp/sources`.

> This repo (`meta-imx93-customization`) is **not** part of that manifest by
> design — it's registered directly in `bblayers.conf` so `repo sync` never
> touches or overwrites it (see the top-level README).

---

## 5. Image Build

### 5.1 Build configurations

`imx-setup-release.sh` sets up a build directory + config files for a chosen
machine + graphical backend. `meta-imx` provides new/updated machine configs
that overlay `meta-freescale`'s; `imx-setup-release.sh` copies these into
`meta-freescale/conf/machine`. Check the release notes or the machine
directory itself for the current, authoritative list — machine names below
are current as of this guide's revision:

<details>
<summary><b>i.MX 6</b></summary>

imx6qpsabresd, imx6ulevk, imx6ulz-14x14-evk, imx6ull14x14evk, imx6ull9x9evk,
imx6dlsabresd, imx6qsabresd, imx6solosabresd, imx6sxsabresd, imx6sllevk
</details>

<details>
<summary><b>i.MX 7</b></summary>

imx7dsabresd, imx7ulpevk
</details>

<details>
<summary><b>i.MX 8</b></summary>

imx8qmmek, imx8qxpc0mek, imx8mqevk, imx8mm-lpddr4-evk, imx8mm-ddr4-evk,
imx8mn-lpddr4-evk, imx8mn-ddr4-evk, imx8mp-lpddr4-evk, imx8mp-ddr4-evk,
imx8mp-lpddr4-frdm, imx8dxla1-lpddr4-evk, imx8dxlb0-lpddr4-evk,
imx8dxlb0-ddr3l-evk, imx8mnddr3levk, imx8ulp-lpddr4-evk,
imx8ulp-9x9-lpddr4x-evk
</details>

**i.MX 9** (this board's family):

- imx91-11x11-lpddr4-evk
- imx91-11x11-lpddr4-frdm
- imx91-11x11-lpddr4-frdm-imx91s
- imx91-9x9-lpddr4-qsb
- imx93-11x11-lpddr4x-evk
- **`imx93-11x11-lpddr4x-frdm`** ← FRDM-IMX93, this board
- imx93-14x14-lpddr4x-evk
- imx93-9x9-lpddr4-qsb
- imx93w-14x12-lpddr4x-evk
- imx93w-14x12-lpddr4x-frdm
- imx943-19x19-lpddr5-evk
- imx943-19x19-lpddr4-evk
- imx943-orangebox
- imx95-15x15-lpddr4x-frdm
- imx95-19x19-lpddr5-evk
- imx95-19x19-lpddr5-frdm-pro
- imx952-15x15-lpddr4x-evk
- imx952-19x19-lpddr5-evk

Each build directory must stick to **one** distro — changing
`DISTRO_FEATURES` requires a clean build directory. `DISTRO`/`MACHINE` are
recorded in that directory's `local.conf` and echoed when bitbake runs.

**DISTRO configurations** (`fsl-imx-fb` is unsupported on i.MX 8/9;
`fsl-imx-x11` no longer supported at all):

| Distro | Graphics |
|---|---|
| `fsl-imx-wayland` | Pure Wayland |
| **`fsl-imx-xwayland`** | Wayland + X11 (X11-over-EGL apps unsupported) — **default if `DISTRO` unset**, and what this board's build uses |
| `fsl-imx-fb` | Framebuffer only — i.MX 6/7 only |

Custom distros are recommended per-customer (copy one of the above, or start
from `poky.conf`) rather than hand-tuning `local.conf` providers/versions.

**Script syntax:**

```
DISTRO=<distro name> MACHINE=<machine name> source imx-setup-release.sh -b <build dir>
```

- `DISTRO` — from `meta-imx/meta-imx-sdk/conf/distro`
- `MACHINE` — from `conf/machine` in `meta-freescale`/`meta-imx`
- `-b <build dir>` — build directory name the script creates

Running it prompts for EULA acceptance (stored per build dir, asked once).
Result: `<build dir>/conf/{bblayers.conf,local.conf}`. `bblayers.conf` lists
every meta-layer in use; `local.conf` carries:

```
MACHINE ??= 'imx7ulpevk'
DISTRO ?= 'fsl-imx-xwayland'
ACCEPT_FSL_EULA = "1"
```

`meta-imx` also ships **consolidated** test-only machine configs
(`imx6qpdlsolox.conf`, `imx6ul7d.conf`) bundling all device trees for one
family into a single image — for NXP-internal testing only, don't use these
otherwise.

`MACHINE=imx943-orangebox` needs its own setup entry point instead of the
generic script:

```
source ./sources/meta-imx-orangebox/tools/setup.sh <build folder>
```

### 5.2 Choosing an i.MX Yocto project image

| Image | Purpose | Layer |
|---|---|---|
| `core-image-minimal` | Smallest bootable image | `openembedded-core` |
| `core-image-base` | Console-only, full HW support | `openembedded-core` |
| `core-image-sato` | Sato mobile UI (Pimlico apps: terminal, editor, file manager) | `openembedded-core` |
| `imx-image-core` | i.MX test apps for Wayland backends; used for daily core testing | `meta-imx/meta-imx-sdk` |
| `fsl-image-machinetest` | Community console-only core image | `meta-freescale-distro` |
| `imx-image-multimedia` | i.MX image with GUI, no Qt | `meta-imx/meta-imx-sdk` |
| `imx-image-full` | Open-source Qt 6 + Machine Learning image. Needs HW graphics — **not** supported on 6UltraLite, 6ULL, 6SLL, 7Dual, 8M Nano Lite, 8DXL | `meta-imx/meta-imx-sdk` |

*(This repo's `imx-image-sec-min`/`imx-image-sec-full` are this layer's own
headless, security-tooling-focused equivalents — not part of the stock list
above. See the top-level repo README.)*

### 5.3 Building an image

```
bitbake imx-image-multimedia
```

`bitbake <component>` builds anything (component or image); an image build
recursively resolves every dependency's fetch/configure/compile/package/
deploy tasks, starting with the toolchain.

### 5.4 Bitbake options

```
bitbake <parameter> <component>
```

| Parameter | Effect |
|---|---|
| `-c fetch` | Fetch only if not already marked done |
| `-c cleanall` | Wipe the component's entire build dir, rootfs/state, **and** its download-dir copy |
| `-c deploy` | Deploy an image/component to the rootfs |
| `-k` | Keep going past a build break |
| `-c compile -f` | Force recompile (needed if you hand-edited sources under the temp/work dir — Yocto won't otherwise notice) |
| `-g` | Print a dependency tree for an image/component |
| `-DDD` | Debug output, 3 levels (stack more `D`s for more) |
| `-s`, `--show-versions` | Show current + preferred version of every recipe |

### 5.5 U-Boot configuration

Set via `UBOOT_CONFIG` in `local.conf` (main machine config file specifies
what's valid); default without it is **SD boot**. Space-separate multiple
configs to build several at once.

Per-board `UBOOT_CONFIG` values (i.MX 6/7 boards support with/without
OP-TEE variants):

<details>
<summary>Full table</summary>

```
uboot_config_imx952evk="sd xspi"
uboot_config_imx95evk="sd fspi"
uboot_config_imx95_frdm="sd"
uboot_config_imx95_frdm_pro="sd"
uboot_config_imx943evk="sd xspi"
uboot_config_imx93evk="sd fspi"
uboot_config_imx93_frdm="sd ecc"        # ← this board
uboot_config_imx91evk="sd nand fspi ecc"
uboot_config_imx91_frdm="sd ecc"
uboot_config_imx91s_frdm="sd nand ecc"
uboot_config_imx8mmevk="sd fspi"
uboot_config_imx8mnevk="sd fspi"
uboot_config_imx8mpevk="sd fspi ecc"
uboot_config_imx8mp_frdm="sd fspi"
uboot_config_imx8mqevk="sd"
uboot_config_imx8dxlevk="sd fspi"
uboot_conifg_imx8dxmek="sd fspi"        # [sic] typo in upstream doc
uboot_config_imx8qxpc0mek="sd fspi"
uboot_config_imx8qxpmek="sd fspi"
uboot_config_imx8qmmek="sd fspi"
uboot_config_imx8ulpevk="sd fspi"
uboot_config_imx8ulp-9x9-lpddr4-evk="sd fspi"
uboot_config_imx6qsabresd="sd sata sd-optee"
uboot_config_imx6qsabreauto="sd sata eimnor spinor nand sd-optee"
uboot_config_imx6dlsabresd="sd epdc sd-optee"
uboot_config_imx6dlsabreauto="sd eimnor spinor nand sd-optee"
uboot_config_imx6solosabresd="sd sd-optee"
uboot_config_imx6solosabreauto="sd eimnor spinor nand sd-optee"
uboot_config_imx6sxsabresd="sd emmc qspi2 m4fastup sd-optee"
uboot_config_imx6sxsabreauto="sd qspi1 nand sd-optee"
uboot_config_imx6qpsabreauto="sd sata eimnor spinor nand sd-optee"
uboot_config_imx6qpsabresd="sd sata sd-optee"
uboot_config_imx6sllevk="sd epdc sd-optee"
uboot_config_imx6ulevk="sd emmc qspi1 sd-optee"
uboot_config_imx6ul9x9evk="sd qspi1 sd-optee"
uboot_config_imx6ull14x14evk="sd emmc qspi1 nand sd-optee"
uboot_config_imx6ull9x9evk="sd qspi1 sd-optee"
uboot_config_imx6ulz14x14evk="sd emmc qspi1 nand sd-optee"
uboot_config_imx7dsabresd="sd epdc qspi1 nand sd-optee"
uboot_config_imx7ulpevk="sd emmc sd-optee"
```
</details>

Build with a config:

```
echo "UBOOT_CONFIG = \"eimnor\"" >> conf/local.conf              # single
echo "UBOOT_CONFIG = \"sd eimnor\"" >> conf/local.conf            # multiple
MACHINE=<machine name> bitbake -c deploy u-boot-imx
```

For this board that's effectively `UBOOT_CONFIG = "sd ecc"` under
`MACHINE=imx93-11x11-lpddr4x-frdm` (or this build tree's `imx93frdm` alias) —
note this layer's own `u-boot-imx_2024.04.bbappend` adds patches on top
regardless of which `UBOOT_CONFIG` value is active (see repo README).

### 5.6 Build scenarios

Base setup for all scenarios below:

```
mkdir imx-yocto-bsp && cd imx-yocto-bsp
repo init -u https://github.com/nxp-imx/imx-manifest \
    -b imx-linux-wrynose -m imx-6.18.20-2.0.0.xml
repo sync
```

#### 5.6.1 i.MX 8M Plus EVK, XWayland

```
DISTRO=fsl-imx-xwayland MACHINE=imx8mpevk source imx-setup-release.sh -b build-xwayland
bitbake imx-image-full
```

XWayland + Qt 6 + ML. Drop Qt6/ML by building `imx-image-multimedia` instead.

#### 5.6.2 i.MX 8M Quad EVK, Wayland

```
DISTRO=fsl-imx-wayland MACHINE=imx8mqevk source imx-setup-release.sh -b build-wayland
bitbake imx-image-multimedia
```

Weston Wayland, multimedia, no Qt 6.

#### 5.6.3 i.MX 6QuadPlus SABRE-AI, Frame Buffer

```
DISTRO=fsl-imx-fb MACHINE=imx6qpsabresd source imx-setup-release.sh -b build-fb
bitbake imx-image-multimedia
```

#### 5.6.4 Restarting a build environment

A fresh shell/reboot doesn't need the full `imx-setup-release.sh` again — just:

```
source setup-environment <build-dir>
```

(This is exactly what this repo's own README recommends over re-running the
full NXP setup script, to avoid the `bblayers.conf` regeneration issue noted
there.)

#### 5.6.5 Chromium Browser on Wayland

Community Chromium recipes for Wayland — **not** NXP-tested/supported.
Requires `meta-browser` (added automatically by `imx-release-setup.sh`).
X11 unsupported; i.MX 6/7 support deprecated, removal planned next release.

```
CORE_IMAGE_EXTRA_INSTALL += "chromium-ozone-wayland"     # local.conf
bitbake-layers add-layer ../sources/meta-browser/meta-chromium
```

#### 5.6.6 Qt 6 and QtWebEngine browsers

Qt 6 has commercial + open-source licenses; **open-source is the Yocto
default**. Once custom development starts under the OSS license it cannot
switch to commercial later — get legal sign-off if this matters.

QtWebEngine is **incompatible** with `meta-chromium` — if using the NXP setup,
comment it out of `bblayers.conf`:

```
# Commented out due to incompatibility with qtwebengine
#BBLAYERS += "${BSPDIR}/sources/meta-browser/meta-chromium"
```

Four bundled Qt 6 browsers (run the executable directly from these dirs):

- `/usr/share/qt6/examples/webenginewidgets/StyleSheetbrowser`
- `/usr/share/qt6/examples/webenginewidgets/Simplebrowser`
- `/usr/share/qt6/examples/webenginewidgets/Cookiebrowser`
- `/usr/share/qt6/examples/webengine/quicknanobrowser`

Touchscreen support: `-plugin evdevtouch:/dev/input/event0`, e.g.
`./quicknanobrowser -plugin evdevtouch:/dev/input/event0`.

Only works on SoCs with GPU graphics HW (i.MX 6/7/8/9). To include it:

```
IMAGE_INSTALL:append = " packagegroup-qt6-webengine"
```

#### 5.6.7 NXP eIQ machine learning

`meta-ml` = NXP eIQ ML integration (formerly a separate
`meta-imx-machinelearning` layer), now folded into the standard
`imx-image-full`. Many features need Qt 6. For any other image:

```
IMAGE_INSTALL:append = " packagegroup-imx-ml"
```

Add eIQ packages to the SDK (not the image itself):

```
TOOLCHAIN_TARGET_TASK:append = " tensorflow-lite-dev onnxruntime-dev"
```

OpenCV DNN demo model configs/input data:

```
PACKAGECONFIG:append:pn-opencv_mx8 = " tests tests-imx"
```

#### 5.6.8 Systemd

Default init manager. To disable, edit `fs-imx-base.inc` and comment out its
systemd section.

*(This layer keeps systemd — `led-ctrl`/`fota-bootloader` both ship as
systemd units.)*

#### 5.6.9 OP-TEE enablement

Needs 3 pieces: OP-TEE OS (in the bootloader), OP-TEE client + test (in the
rootfs), plus kernel/U-Boot config. **Enabled by default.** To disable, edit
`meta-imx/meta-imx-bsp/conf/layer.conf`: comment out the OP-TEE
`DISTRO_FEATURES_append` line, uncomment the "removed" line.

*(`imx-image-sec-min` explicitly installs `packagegroup-fsl-optee-imx` — see
repo README.)*

#### 5.6.10 Building Jailhouse

Static-partitioning hypervisor on Linux. Supported on i.MX 8M Plus, 8M Nano,
8M Quad EVK, 8M Mini EVK, **i.MX 93**, i.MX 95, i.MX 943.

```
DISTRO_FEATURES:append = " jailhouse"        # local.conf
```

At the U-Boot prompt: `run jh_netboot` or `run jh_mmcboot` (loads the
Jailhouse-specific DTB). After Linux boots (i.MX 8M Quad example):

```
modprobe jailhouse
./jailhouse enable imx8mq.cell
```

Full detail: i.MX Linux User's Guide (UG10163).

#### 5.6.11 NXP Gitee mirror

Mirrors NXP's public GitHub repos on Gitee, for faster/more stable access in
regions where GitHub is slow/restricted (e.g. China). Config fragment
`yocto/nxp-gitee-mirror.conf` lives in `meta-imx`:

```
bitbake-config-build enable-fragment fsl-sdk-release/yocto/nxp-gitee-mirror
```

Once enabled, `github.com/nxp-imx` fetches transparently redirect to
`gitee.com/nxp-china` — no recipe/layer-config changes needed.

#### 5.6.12 Yocto Toaster

Web UI for OpenEmbedded builds.

```
cd openembedded-core
source oe-init-build-env
source toaster start
```

Then open `http://127.0.0.1:8000`. In the UI: create a project (pick the
release, e.g. Walnascar), configure Machine/Distro/target recipe
(`imx-image-multimedia`), and ensure these layers are present:

```
meta-imx-bsp, meta-imx-sdk, openembedded-core, meta-poky, meta-yocto-bsp,
meta-freescale-distro, meta-freescale, meta-oe, meta-security, meta-perl,
meta-arm-toolchain, meta-arm, meta-clang, meta-python, meta-networking,
meta-multimedia, meta-virtualization
```

Click Build, monitor progress in the web UI. See the Toaster User Manual for
more.

---

## 6. Image Deployment

Complete images land in `<build directory>/tmp/deploy/images/<machine>/`.
Each image build produces U-Boot, kernel, and whatever `IMAGE_FSTYPES` the
machine config specifies — typically an SD card image (`.wic`) and a rootfs
tarball (`.tar`). The `.wic` is a fully partitioned image (U-Boot, kernel,
rootfs, ...) ready to boot the target hardware as-is.

### 6.1 Flashing an SD card image

```
zstdcat <image_name>.wic.zst | sudo dd of=/dev/sd<partition> bs=1M conv=fsync
```

Full procedure: "Preparing an SD/MMC card to boot" in UG10163.

For NXP eIQ ML images, budget an extra ~1 GB free space via
`IMAGE_ROOTFS_EXTRA_SPACE` in `local.conf` before building (see the Yocto
Project Mega-Manual).

*(This repo's own `netflash`/`--flash-boot` mechanisms in
`meta-imx93-customization` are alternatives to this manual `dd` step — see
top-level README.)*

---

## 7. Customization

Three ways to build/customize i.MX Linux:

1. Build the stock i.MX Yocto BSP against a reference board (this document).
2. Customize kernel/board/device-tree + U-Boot standalone, outside the full
   Yocto build (see "How to build U-Boot and Kernel in standalone
   environment", UG10163).
3. **Customize a distribution** by adding/removing packaging via a custom
   Yocto layer (what `meta-imx93-customization` itself is an example of).

### 7.1 Creating a custom distro

`fsl-imx-wayland`/`fsl-imx-xwayland`/`fsl-imx-fb` are themselves just example
distro configs (graphics backend + kernel/U-Boot/GStreamer parameters).
Recommended practice: create your own distro file per customer/project rather
than hand-patching `local.conf` providers/versions — start from an existing
distro file (or `poky.conf`) and layer changes on top.

### 7.2 Creating a custom board configuration

For vendors upstreaming a new reference board into the FSL Community BSP
(shares source with the community, gets community feedback/testing):

1. Get a working, stable Linux kernel + bootloader (e.g. U-Boot) for the
   board **before** starting the upstream process.
2. Customize kernel config (`arch/arm/configs`) via the vendor kernel recipe.
3. Customize U-Boot as needed (see UG10165, i.MX Porting Guide).
4. Assign a board maintainer, responsible for keeping the board's core
   packages, kernel, and bootloader up to date and tested.
5. Set up the community Yocto build (master branch):
   ```
   mkdir imx-community-bsp && cd imx-community-bsp
   repo init -u https://github.com/Freescale/fsl-community-bsp-platform -b master
   repo sync
   source setup-environment build
   ```
6. Copy a similar existing machine file from
   `fsl-community-bsp/sources/meta-freescale-3rdparty/conf/machine`, rename
   it for the new board, edit name/description/`MACHINE_FEATURE` at minimum.
7. Validate against latest community master, at least with
   `bitbake core-image-minimal`.
8. Prepare patches per the Recipe Style Guide and the "Contributing" section
   of `github.com/Freescale/meta-freescale/blob/master/README.md`.
9. Upstream into `meta-freescale-3rdparty` by mailing patches to
   `meta-freescale@yoctoproject.org`.

### 7.3 Monitoring security vulnerabilities in your BSP

Two independent mechanisms:

#### 7.3.1 Vigiles (Timesys)

Build-time CVE analysis: collects BSP software metadata and cross-references
a CVE database (NIST, Ubuntu, others). Produces a high-level summary plus a
detailed online report (severity, available fixes).

Register: <https://www.timesys.com/register-nxp-vigiles/>. More setup info:
<https://github.com/TimesysGit/meta-timesys>, <https://www.nxp.com/vigiles>.

**Configuration** — add to `conf/bblayers.conf`:

```
BBLAYERS += "${BSPDIR}/sources/meta-timesys"
```

and to `conf/local.conf`:

```
INHERIT += "vigiles"
```

**Execution** — runs automatically on every build once configured; no extra
commands. Output: `imx-yocto-bsp/<build dir>/vigiles/`. View via:

- CLI summary: open `<image name>-report.txt` (also links to the full online
  report).
- Full detail: online, via the link in that file.

Full CVE reporting (beyond Demo Mode summaries) needs a **LinuxLink License
Key**: register/log in at timesys.com, generate a key under Preferences,
download it, then point to it:

```
VIGILES_KEY_FILE = "/tools/timesys/linuxlink_key"     # local.conf
```

Get the layer:

```
git clone https://github.com/TimesysGit/meta-timesys.git -b master   # in sources/
```

#### 7.3.2 Yocto's own CVE check (`sbom-cve-check`)

Yocto's built-in infra tracking public CVEs. Enable for a build:

```
OE_FRAGMENTS += "core/yocto/sbom-cve-check"     # local.conf
```

Generate a report:

```
bitbake -c sbom_cve_check <image>
```

(`bitbake -c sbom_cve_check <package>` — package-level, rather than
image-level — may not work.) Report location:

```
<build-dir>/tmp/deploy/images/<machine name>/<image>-<machine name>.rootfs.sbom-cve-check.yocto.json
```

More detail: "Classes" (§6) in the Yocto Project Reference Manual.

---

## 8. Frequently Asked Questions

### 8.1 Quick Start

Condensed end-to-end setup:

```
# Once: install repo
mkdir ~/bin
curl https://storage.googleapis.com/git-repo-downloads/repo > ~/bin/repo
chmod a+x ~/bin/repo
PATH=${PATH}:~/bin

# Once per release: fetch the BSP
mkdir imx-yocto-bsp && cd imx-yocto-bsp
repo init -u https://github.com/nxp-imx/imx-manifest -b imx-linux-wrynose -m imx-6.18.20-2.0.0.xml
repo sync
```

(Manifest list: <https://github.com/nxp-imx/imx-manifest/tree/imx-linux-wrynose>.)

Framebuffer backend is i.MX 6/7 **only**.

```
# Framebuffer
DISTRO=fsl-imx-fb MACHINE=<machine name> source imx-setup-release.sh -b build-fb
# Wayland
DISTRO=fsl-imx-wayland MACHINE=<machine name> source imx-setup-release.sh -b build-wayland
# XWayland
DISTRO=fsl-imx-xwayland MACHINE=<machine name> source imx-setup-release.sh -b build-xwayland

# Build, without Qt
bitbake imx-image-multimedia
# Build, with Qt 6 + ML
bitbake imx-image-full
```

### 8.2 Local configuration tuning

To share `sstate-cache`/`downloads` across multiple build directories (saves
disk + rebuild time), in `local.conf`:

```
DL_DIR="/opt/imx/yocto/imx/download"
SSTATE_DIR="/opt/imx/yocto/imx/sstate-cache"
```

(Directories must already exist with correct permissions; unset, Yocto
defaults both to inside the build directory.)

Every fetched package in `DL_DIR` gets a `<package name>.done` marker. If a
fetch fails due to network issues, manually place a known-good copy in
`DL_DIR` and `touch <package_name>.done`, then re-run
`bitbake <component>`.

More: Yocto Project Reference Manual.

### 8.3 Recipes

Each component = one recipe (points at `SRC_URI`, plus patches). Autotools
builds should `inherit autotools pkgconfig`; the Makefile must let `CC` be
overridden for cross-compilation.

To append a patch to an existing recipe without forking it, use a
`.bbappend`:

```
FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"
SRC_URI += " file://<patch name>.patch"
```

`FILESEXTRAPATHS:prepend` tells bitbake where to look for files referenced in
`SRC_URI`.

> If a `.bbappend` doesn't seem to take effect, check `log.do_fetch` under the
> recipe's work directory to confirm the patch was actually picked up — a
> `_git` (AUTOREV) version of the recipe may be shadowing the versioned one
> the `.bbappend` targets.

*(This is exactly the pattern this layer's own `.bbappend` files —
`u-boot-imx_2024.04.bbappend`, `imx-atf_%.bbappend`,
`fscrypt_1.1.0.bbappend` — follow; see repo README for specifics.)*

### 8.4 How to select additional packages

Search <https://layers.openembedded.org/> for community recipes before
writing your own.

#### 8.4.1 Updating an image

An image recipe (e.g. `imx-image-multimedia.bb`) lists the packages that go
into the rootfs. Built artifacts (rootfs, kernel, modules, U-Boot) land in
`build/tmp/deploy/images/<machine name>/`.

> A package can be built without being included in any image — but the image
> must be **rebuilt** for that package to actually land on a rootfs.

#### 8.4.2 Package group

A set of packages includable as a unit in any image — e.g. a multimedia
package group can conditionally pull in the VPU package per-machine, so
every board gets the right multimedia set from one include. Package groups
live in `packagegroup*` subdirectories.

Add extra packages to an image without editing the image recipe:

```
CORE_IMAGE_EXTRA_INSTALL:append = " <package_name1 package_name2>"    # local.conf
```

#### 8.4.3 Preferred version

Pins which version of a multi-version recipe to use.

```
PREFERRED_VERSION_<component>:<soc family> = "<version>"
```

`meta-imx/layer.conf` sets preferred versions broadly, for a static/
production-like environment (formal i.MX releases) — not essential for
day-to-day development. `_git` recipe variants are otherwise usually
preferred over static-version ones unless pinned.

#### 8.4.4 Preferred provider

Pins which of several providers of a component to use — e.g. U-Boot has both
`u-boot-fslc` (community, denx.de) and `u-boot-imx` (NXP):

```
PREFERRED_PROVIDER_<component>:<soc family> = "<provider>"
PREFERRED_PROVIDER_u-boot_mx6 = "u-boot-imx"
```

#### 8.4.5 SoC family

A class of related SoCs sharing certain changes; each machine config lists
its SoC family/families (e.g. 6DualLite Sabre-SD → `mx6` + `mx6dl`). Lets
`local.conf` target a class rather than one machine:

```
KERNEL_DEVICETREE:mx6dl = "imx6dl-sabresd.dts"
```

Useful for hardware-class-specific settings — e.g. i.MX 28 EVK has no VPU, so
VPU settings should target `mx5`/`mx6` specifically, not something broader.

#### 8.4.6 BitBake logs

```
tmp/work/<architecture>/<component>/temp/
```

- Fetch failure → `log.do_fetch`
- Compile failure → `log.do_compile`
- Deploy looks wrong → check `package`, `packages-split`, `sysroot*` under
  `tmp/work/<architecture>/<component>/` (staging areas before the deploy
  copy).

#### 8.4.7 CVE monitoring/notification setup

```
cd imx-yocto-bsp/sources
git clone https://github.com/TimesysGit/meta-timesys.git -b master
```

See [§7.3](#73-monitoring-security-vulnerabilities-in-your-bsp) for usage.
Full reporting needs a LinuxLink key (Demo Mode otherwise — summaries only).
Register/generate at timesys.com → Preferences → New Key, then:

```
VIGILES_KEY_FILE = "/tools/timesys/linuxlink_key"     # local.conf
```

---

## 9. References

- Boot switches: "How to Boot the i.MX Boards", UG10163.
- Downloading images via U-Boot: "Downloading Images Using U-Boot", UG10163.
- SD/MMC card setup: "Preparing an SD/MMC Card to Boot", UG10163.

## 10. Note about source code in the document

Example code in the original document is BSD-3-Clause, © 2026 NXP.

## 11. Revision history (abridged)

Full table condensed to the entries relevant to this board's software stack
(i.MX 93 / recent kernels); see the source document for the complete
20+-entry history back to 2017.

| Doc rev | Date | Substantive changes |
|---|---|---|
| LF6.18.20_2.0.0 | 2026-06-25 | Kernel → 6.18.20; removed i.MX 95 15x15 EVK + i.MX 95 19x19 Verdin; added i.MX 93W + i.MX 952 |
| LF6.18.2_1.0.0 | 2026-03-26 | Kernel → 6.18.2; removed i.MX 8DXL Orange Box; added i.MX 943 OrangeBox |
| LF6.12.49_2.2.0 | 2026-01-14 | Updated Yocto Project version reference |
| LF6.12.49_2.2.0 | 2025-12-12 | Kernel → 6.12.49; added **i.MX 95 FRDM** |
| LF6.12.34_2.1.0 | 2025-09-25 | Kernel → 6.12.34; i.MX 943 A0 + i.MX 95 B0 Beta; added **i.MX 8MP/91/93 FRDM boards** ← this board's FRDM support first landed here |
| LF6.12.20_2.0.0 | 2025-06-26 | Kernel → 6.12.20, U-Boot v2025.04, TF-A 2.11, OP-TEE 4.6.0, Yocto 5.2 "Walnascar"; i.MX 943 Alpha |
| LF6.12.3_1.0.0 | 2025-03-31 | Kernel → 6.12.3 |
| LF6.6.52_2.2.0 | 2024-12-16 | Kernel → 6.6.52 |
| LF6.6.36_2.1.0 | 2024-09-30 | Kernel → 6.6.36 |
| LF6.6.23_2.0.0 | 2024-06-28 | Kernel → 6.6.23, U-Boot v2024.04, TF-A v2.10, OP-TEE 4.2.0, Yocto 5.0 "Scarthgap"; i.MX 91 Alpha, i.MX 95 Beta |

*(Older history, 2017–2024, spanning i.MX 6/7/8 bring-up, omitted here — see
the source `.txt` at `/home/khaled/Desktop/IMX93/Documents/UG10164.txt` if
needed.)*

---

## Document info

- **Source**: NXP UG10164, *i.MX Yocto Project User's Guide*, Rev.
  LF6.18.20_2.0.0, 25 June 2026, © NXP B.V.
- **Keywords**: i.MX, Linux, Yocto, UG10164, LF6.18.20_2.0.0
- Legal disclaimers, trademark notices, and the full BSD-3-Clause example-code
  license from the original PDF are omitted here for brevity — see the
  original document/`nxp.com` for the authoritative legal text if that ever
  matters (e.g. redistribution).
