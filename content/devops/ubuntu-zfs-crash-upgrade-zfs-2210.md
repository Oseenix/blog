---
title: "Fixing Ubuntu 24.04 ZFS Root Crashes: Upgrading OpenZFS 2.2.2 to 2.2.10"
description: "A kernel panic that looked 100% like a ZFS bug — matching stack trace, matching upstream PR — turned out to be an Intel Raptor Lake CPU microcode bug. A debugging case study on not trusting panic location, plus the full walkthrough: diagnosing the crash, building ZFS 2.2.10 on GitHub Actions around a frozen Ubuntu package, fixing initramfs module loading, and restoring the Plymouth LUKS unlock screen."
categories:
  - DevOps
tags:
  [
    ubuntu,
    zfs,
    openzfs,
    kernel,
    initramfs,
    luks,
    encryption,
    dkms,
    plymouth,
    boot,
  ]
date: 2026-07-07
toc: true
draft: false
type: posts
author: Jinze Zhou
---

This started as what looked like an open-and-shut ZFS bug: a kernel panic with a clean stack
trace, matching a known upstream issue that already had its own PR number attached. It wasn't.
The actual root cause sat one layer below the kernel entirely — and getting from "random
freezes" to "confirmed fixed" meant cross-compiling ZFS off-machine because the live system
couldn't survive its own build, then reverse-engineering an undocumented Ubuntu encryption
mechanism that no upstream package ships. Here's the full chain, and what's worth keeping from
it.

## 1. The Symptoms

The workstation (Ubuntu 24.04.4 LTS, kernel 6.8.0-134-generic) started
freezing randomly — sometimes hours apart, sometimes minutes. The only clue was in `dmesg`:

```text
[5211.336041] mce: [Hardware Error]: Machine check events logged
[5214.002311] BUG: kernel NULL pointer dereference, address: 0000000000000018
[5214.002318] Call Trace:
[5214.002319]  dbuf_hold_impl+0x1a3/0x5b0 [zfs]
[5214.002334]  dmu_read_uio_dbuf+0x7b/0x110 [zfs]
[5214.002347]  zfs_read+0x1a7/0x3d0 [zfs]
```

The crash was always inside the ZFS read path: `dbuf_hold_impl → dmu_read_uio_dbuf → zfs_read`.
The pattern matches a freed `dmu_buf_impl_t` being accessed. MCE events also appeared before
the crash; their significance became clear only after the full investigation.

## 2. Root Cause

The crash traces always pointed to the ZFS read path, but the root cause has since been
confirmed: a CPU microcode bug, not ZFS.

**Intel Raptor Lake microcode — confirmed root cause.** The CPU belongs to the generation
affected by the Vmin Shift Instability — a voltage bug causing computation errors under
sustained load. Intel released a microcode fix in 2024, but the BIOS on this machine dated from
November 2022 and had never been updated. Even after the CPU was replaced under warranty, the
replacement unit was still running the unfixed microcode. MCE events were occurring
continuously but went unnoticed. Updating the BIOS to V17.I (April 2026, which includes the
updated Intel microcode) stabilized the system immediately — no crash has recurred since,
confirming the CPU microcode bug, not ZFS, was the actual trigger.

**ZFS 2.2.2 dbuf issues — precautionary upgrade, not the fix.** ZFS 2.2.3 contains several fixes
to the dbuf code path, including a lock leak in `dbuf_hold()` error handling
([PR #15644](https://github.com/openzfs/zfs/pull/15644)). Whether these directly correspond to
the crash at `dbuf_hold_impl → dmu_read_uio_dbuf → zfs_read` remains unknown — no PR was found
explicitly targeting this read path, and the system's continued stability doesn't hinge on this
upgrade either way. ZFS was still upgraded to 2.2.10, purely as defense-in-depth.

The trigger in every observed crash was the same: sustained concurrent reads on the ZFS
filesystem — which is what made a CPU voltage bug manifest as a ZFS-shaped panic.

- **Trilium Notes** — SQLite database on ZFS, frequent concurrent background reads
- **Local compilation** — reading thousands of source files through ZFS mid-build
- **DKMS builds** — background compilation reading ZFS source files

This is also why the fix had to be built **off-machine** on GitHub Actions: every attempt to
compile on the live system ended in a crash, making it impossible to fix from inside the
problem.

## 3. Why 2.2.10?

The bug is fixed in any version ≥ 2.2.3. The choice of 2.2.10 specifically comes from three
constraints:

**Stay on the 2.2.x branch, not 2.3.x or 2.4.x.** Ubuntu 24.04 ships ZFS 2.2.2 as its
supported version. Its `zfs-initramfs` boot scripts, pool cache format, and feature flags are
all written against 2.2.x. Jumping to 2.4.x introduces unnecessary risk: the upstream
`openzfs-zfs-initramfs` in 2.4.x has a different boot architecture and would require more
extensive initramfs surgery. The 2.2.x branch is also the one Ubuntu 24.04 will continue to
maintain for security patches.

**2.2.10 is the latest 2.2.x release as of July 2026.** Taking the latest patch release means
getting all bug fixes since 2.2.3 in one shot — including additional read-path stability
improvements beyond just the use-after-free fix.

**Pool feature compatibility.** ZFS pools carry a feature flags version. Staying on 2.2.x means
the pools remain compatible with Ubuntu's stock ZFS if a rollback is ever needed. Running
`zpool upgrade` to 2.4.x features would make the pools unreadable by 2.2.x — an irreversible
change.

## 4. Why Not Just Upgrade the Kernel or `apt upgrade`?

### Upgrading the kernel doesn't help

This is the most natural first instinct — and it doesn't work. Ubuntu 24.04's ZFS version is
**decoupled from the kernel version**. The kernel module lives in
`linux-modules-extra-<kver>`, a separate package that Ubuntu builds and freezes independently.
Even if you upgrade to the latest HWE kernel (e.g. 6.11.x via
`linux-hwe-6.11-modules-extra`), the ZFS module inside is still 2.2.2 — Ubuntu packages it
that way for the entire 24.04 LTS lifecycle. Upgrading the kernel changes the ABI the module
runs against, not the ZFS version itself.

### `apt upgrade` is also frozen

`zfsutils-linux` and the associated library packages are pinned to 2.2.2 in Ubuntu 24.04's
archive. There is no newer ZFS in the Noble pocket. `apt` simply has nothing to offer.

The canonical path is to wait for Ubuntu 26.04 (which ships ZFS 2.4.1), but that upgrade
channel only opens after 26.04.1 releases (~August 2026). We needed the fix now.

Ubuntu has released several patch versions of `zfs-linux 2.2.2` for Noble since launch —
`2.2.2-0ubuntu9` through `2.2.2-0ubuntu9.3` as of July 2026. The updates address kernel
compatibility issues (Linux 6.7, 6.8), performance fixes, and isolated panics. None of them
backport the `dbuf_hold_impl` use-after-free fix from ZFS 2.2.3. The read-path crash in 2.2.2
was never patched (see the
[Noble zfs-linux changelog on Launchpad](https://launchpad.net/ubuntu/+source/zfs-linux/+changelog)).

## 5. Building ZFS 2.2.10 on GitHub Actions

Since compiling ZFS on the live system would trigger the very bug we were trying to fix (reading
source files through the broken ZFS), we used GitHub Actions to cross-compile.

### 5.1 The Workflow

Key requirements for the build:

- Target kernel: `6.8.0-134-generic` (must match exactly)
- Produce `.deb` packages for easy installation
- Compile kernel modules with DKMS
- **Compress `.ko` as `.ko.zst`** — Ubuntu 24.04 uses zstd-compressed modules; uncompressed `.ko`
  files are silently skipped by `dracut-install` when building initramfs

```yaml
- name: Install dependencies
  run: |
    sudo apt-get install -y \
      linux-headers-6.8.0-134-generic \
      debhelper dkms zstd gcc-12 ccache ...

- name: Build deb packages
  run: |
    cd zfs-2.2.10
    ./configure --with-linux=/usr/src/linux-headers-6.8.0-134-generic
    cp -r contrib/debian debian
    DEB_BUILD_OPTIONS="nodoc nocheck parallel=$(nproc)" dpkg-buildpackage -us -uc -b -d

- name: Compile kernel modules via DKMS
  run: |
    sudo dpkg -i openzfs-zfs-dkms_2.2.10-1_all.deb || true
    sudo dkms build zfs/2.2.10 -k 6.8.0-134-generic

- name: Package kernel modules (zstd-compressed)
  run: |
    MODDIR=/var/lib/dkms/zfs/2.2.10/6.8.0-134-generic/x86_64/module
    for ko in ${MODDIR}/*.ko; do
      zstd -19 -T0 "$ko" -o "${DESTDIR}/$(basename ${ko}).zst"
    done
```

The full workflow is at [github.com/Oseenix/zfs-build](https://github.com/Oseenix/zfs-build).

## 6. Installing the Packages

> **Prerequisite — Disable Secure Boot first.**
> The modules built here are **not signed** by Ubuntu's kernel signing key. With Secure Boot
> enabled, the kernel will refuse to load them at boot, dropping you to busybox with
> `Failed to load ZFS modules` regardless of whether everything else is correct.
> Disable Secure Boot in your UEFI firmware settings before proceeding.
> To keep Secure Boot enabled, the modules would need to be signed with a custom MOK
> (Machine Owner Key) — that process is out of scope for this post.

Download the artifact and install. The packages conflict with Ubuntu's `zfsutils-linux` family,
so `--force-conflicts` is required:

> **Before installing**: take a recursive ZFS snapshot as a rollback point.
>
> ```bash
> sudo zfs snapshot -r rpool/ROOT/ubuntu_zxbk71@before-zfs-upgrade
> ```

```bash
cd ~/zfs-debs3

sudo dpkg -i --force-overwrite --force-conflicts \
    openzfs-libnvpair3_2.2.10-1_amd64.deb \
    openzfs-libuutil3_2.2.10-1_amd64.deb \
    openzfs-libzfs4_2.2.10-1_amd64.deb \
    openzfs-libzpool5_2.2.10-1_amd64.deb \
    openzfs-libzfsbootenv1_2.2.10-1_amd64.deb \
    openzfs-zfsutils_2.2.10-1_amd64.deb \
    openzfs-zfs-zed_2.2.10-1_amd64.deb \
    openzfs-zfs-initramfs_2.2.10-1_all.deb \
    openzfs-zfs-modules-6.8.0-134-generic_2.2.10-1_amd64.deb

sudo depmod -a 6.8.0-134-generic
sudo reboot
```

## 7. The initramfs Rabbit Hole

This is where the real work began. After installation and reboot:

```text
Failed to load ZFS modules.
Manually load the modules and exit.
```

Dropped to busybox. Three separate problems compounded on each other.

### 7.1 Problem 1: Uncompressed `.ko` Ignored by initramfs

The upstream `openzfs-zfs-initramfs` package uses `dracut-install` internally to copy kernel
modules into the initramfs. On Ubuntu 24.04, all kernel modules use `.ko.zst` (zstd compression).
The `dracut-install` tool silently skips uncompressed `.ko` files.

**Fix**: compress the modules before packaging them in the GitHub Actions workflow (see the
`zstd -19` step above).

### 7.2 Problem 2: `modules.dep` Not Updated

Even with correctly compressed modules, `depmod` needs to be run _after_ installation to register
them in `modules.dep`. Without this, `modprobe zfs` fails silently inside initramfs.

```bash
sudo depmod -a 6.8.0-134-generic
grep "zfs\|spl" /usr/lib/modules/6.8.0-134-generic/modules.dep
# Should show:
# updates/dkms/spl.ko.zst:
# updates/dkms/zfs.ko.zst: updates/dkms/spl.ko.zst
```

Then regenerate initramfs:

```bash
sudo update-initramfs -u -k 6.8.0-134-generic
```

Verify the modules are inside the new initramfs:

```bash
lsinitramfs /boot/initrd.img-6.8.0-134-generic | grep "zfs.ko"
# Should show: usr/lib/modules/6.8.0-134-generic/updates/dkms/zfs.ko.zst
```

### 7.3 Problem 3: Missing LUKS Keystore Unlock Logic

Ubuntu 24.04's ZFS encryption setup uses a layered approach:

```mermaid
flowchart TD
    A[GRUB] --> B[initramfs]
    B --> C[modprobe zfs]
    C --> D[zpool import rpool -N]
    D --> E[/dev/zvol/rpool/keystore appears]
    E --> F[cryptsetup luksOpen\nPlymouth password prompt]
    F --> G[mount /dev/mapper/keystore-rpool\n→ /run/keystore/rpool/]
    G --> H[zfs load-key rpool\nreads system.key]
    H --> I[mount rpool/ROOT/ubuntu_*\n→ /root]
    I --> J[pivot_root — boot complete]
```

The upstream `openzfs-zfs-initramfs` 2.2.10 package ships a `scripts/zfs` that does support ZFS
native encryption (`decrypt_fs()` prompts via Plymouth and calls `zfs load-key` directly) — but
it has **no awareness of Ubuntu's LUKS keystore layer**. It never looks for the `keystore` zvol,
so on this setup it just hangs waiting for a key it can never reach.

Ubuntu's own `zfs-initramfs` package contains a customized `scripts/zfs` with the full keystore
unlock sequence. Since `openzfs-zfs-initramfs` replaced `zfs-initramfs`, this logic was lost.

**Fix**: extract the Ubuntu-patched `scripts/zfs` from the working 6.8.0-124-generic initramfs
and use it for the 6.8.0-134-generic initramfs:

```bash
# Extract the working initramfs
mkdir /tmp/ie124 && unmkinitramfs /boot/initrd.img-6.8.0-124-generic /tmp/ie124

# Replace the upstream script with Ubuntu's version
sudo cp /tmp/ie124/main/scripts/zfs /usr/share/initramfs-tools/scripts/zfs

# Rebuild
sudo update-initramfs -u -k 6.8.0-134-generic
```

The Ubuntu-patched version contains this keystore scanning block (around line 976):

```sh
# Open and mount luks keystore for any pools using one
CRYPTROOT=/scripts/local-top/cryptroot
if [ -x "${CRYPTROOT}" ]; then
    TABFILE=/cryptroot/crypttab
    :>"${TABFILE}"
    # Wait for keystore zvols to appear
    NUMKS=$(zfs list -H -o name | grep '/keystore$' | wc -l)
    while [ ${NUMKS} -ne $(find /dev/zvol/ -name 'keystore' | wc -l) ]; do
        sleep .1
    done
    # Write a temporary crypttab and call cryptroot
    for ks in $(find /dev/zvol/ -name 'keystore'); do
        pool="$(basename $(dirname ${ks}))"
        echo "keystore-${pool} ${ks} none luks,discard" >> "${TABFILE}"
    done
    ${CRYPTROOT}
    # Mount unlocked keystore volumes
    for dev in $(find /dev/mapper -name 'keystore-*'); do
        storepath="/run/$(echo $(basename ${dev})|sed -e 's,-,/,')"
        mkdir -p "${storepath}"
        mount "${dev}" "${storepath}"
    done
fi
```

It also calls `decrypt_fs` inside `mount_fs`, which triggers `zfs load-key` once the keyfile is
accessible.

## 8. Verification

After all fixes and a final reboot:

```bash
uname -r
# 6.8.0-134-generic

zfs version
# zfs-2.2.10-1
# zfs-kmod-2.2.10-1
```

The Plymouth LUKS password prompt appears automatically at boot. One password entry unlocks
everything.

## 9. What Actually Broke (Quick Reference)

| Layer              | Problem                                                    | Fix                                                           | Status               |
| ------------------ | ----------------------------------------------------------- | -------------------------------------------------------------- | -------------------- |
| CPU / BIOS          | Vmin Shift Instability — unpatched Raptor Lake microcode    | Update BIOS to V17.I                                            | Confirmed root cause |
| ZFS kernel module   | `dbuf_hold_impl` use-after-free in 2.2.2 (relevance unconfirmed) | Build 2.2.10 on GitHub Actions                              | Precautionary        |
| Module packaging    | `.ko` not compressed as `.ko.zst`                            | Add `zstd -19` in CI                                            | Required for upgrade |
| `modules.dep`       | Not updated after install                                   | Run `depmod -a` + `update-initramfs`                            | Required             |
| initramfs scripts   | Upstream `openzfs-zfs-initramfs` has no LUKS-keystore support | Copy Ubuntu-patched `scripts/zfs` from 124-generic initramfs | Required              |

## 10. Notes on Ubuntu 26.04

Ubuntu 26.04 ships ZFS 2.4.1 with full official support. The correct long-term fix is to upgrade
once the 24.04 → 26.04 upgrade channel opens (expected after 26.04.1, ~August 2026). Until then,
this workaround keeps the system stable. Do **not** run `zpool upgrade` — it would make the pools
incompatible with ZFS 2.2.x if a rollback were ever needed.

## 11. What This Was Actually About

Three weeks past the BIOS update, the machine hasn't dropped once — through the same Trilium
background reads, the same local compiles, the same DKMS rebuilds that used to take it down
within hours. The ZFS upgrade never got to prove itself the fix; it just sits there as
insurance.

None of the four things worth keeping from this are actually about ZFS:

- **Panic location ≠ root cause.** Every crash traced perfectly through
  `dbuf_hold_impl → dmu_read_uio_dbuf → zfs_read`, and a matching upstream bug even had a PR
  number attached — that was the trap. The real signal was the `mce: [Hardware Error]` line
  sitting one line above every trace, ignored for weeks because the ZFS-shaped stack trace read
  as more legible. Memory corruption from a bad CPU surfaces wherever the kernel next happens to
  touch that memory, and looks exactly like a bug in whatever subsystem is running at the time.
- **Cross-compile around a frozen, bug-blocked package.** Ubuntu 24.04 pins ZFS at 2.2.2
  independent of the kernel version, with no `apt` path forward until the next LTS, and
  compiling locally re-triggered the very bug being fixed. Building on GitHub Actions and
  force-installing the result generalizes to any frozen/broken package, not just ZFS.
- **Upstream package ≠ distro behavior.** OpenZFS's own `openzfs-zfs-initramfs` deb never
  picked up the LUKS-keystore unlock logic that lives only in Ubuntu's downstream fork of the
  same script — an invisible gap between "upstream" and "what your distro actually ships,"
  undocumented on either side.
- **13th/14th-gen Intel crashes: check BIOS microcode first.** The Vmin Shift Instability bug
  predates most of the software stacks it gets blamed on — this one included.
