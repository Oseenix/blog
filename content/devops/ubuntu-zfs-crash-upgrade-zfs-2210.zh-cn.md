---
title: "修复 Ubuntu 24.04 ZFS 根文件系统崩溃：从 OpenZFS 2.2.2 升级到 2.2.10"
description: "一次看起来 100% 是 ZFS bug 的内核 panic——堆栈对得上、上游还有对应 PR 编号——最后查出来是 Intel Raptor Lake CPU 微码问题。一篇关于「别轻信 panic 发生位置」的排查方法论记录，附完整实操：诊断崩溃、在 GitHub Actions 上编译 ZFS 2.2.10 绕过 Ubuntu 冻结包、修复 initramfs 模块加载、恢复 Plymouth LUKS 解密界面。"
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

这原本看起来是一桩板上钉钉的 ZFS bug：堆栈清晰完整，还正好能对上一个上游已有编号的
已知问题，但真正的根因在内核之下的另一层——从"随机冻结"查到"确认修复"，中间绕了
一大圈：本机没法编译自己的修复版本（编译过程本身会触发这个 bug），只能去云端交叉
编译；之后又撞上一套上游文档里没有记载的 Ubuntu 加密机制。下面是排查链路，以及
几条经验。

## 1. 问题现象

工作站（Ubuntu 24.04.4 LTS，内核 6.8.0-134-generic）开始随机冻结，
间隔有时数小时，有时仅几分钟。`dmesg` 留下唯一线索：

```text
[5211.336041] mce: [Hardware Error]: Machine check events logged
[5214.002311] BUG: kernel NULL pointer dereference, address: 0000000000000018
[5214.002318] Call Trace:
[5214.002319]  dbuf_hold_impl+0x1a3/0x5b0 [zfs]
[5214.002334]  dmu_read_uio_dbuf+0x7b/0x110 [zfs]
[5214.002347]  zfs_read+0x1a7/0x3d0 [zfs]
```

崩溃始终发生在 ZFS 读路径：`dbuf_hold_impl → dmu_read_uio_dbuf → zfs_read`，
这与已释放的 `dmu_buf_impl_t` 被访问的模式一致。崩溃前也出现了 MCE 事件，
其意义在完整排查之后才变得清晰。

## 2. 根本原因

崩溃堆栈始终指向 ZFS 读路径，但根本原因事后已确认：真正的触发源是 CPU 微码 bug，而非 ZFS。

**Intel Raptor Lake 微码问题——已确认的根本原因。** 这台机器的 CPU 属于受 Vmin Shift
Instability 影响的那一代——一个在持续高负载下导致计算错误的电压 bug。Intel 于 2024 年
发布了微码修复，但主板 BIOS 停留在 2022 年 11 月的版本，从未更新。即使 CPU 已通过
售后换新，替换后的 CPU 仍在运行未修复的旧微码。MCE 事件持续发生但未被注意到。
将 BIOS 升级至 V17.I（2026 年 4 月，包含更新后的 Intel 微码）后，系统立即恢复稳定——
此后再未复现崩溃，证实了真正的触发源就是 CPU 微码 bug，与 ZFS 无关。

**ZFS 2.2.2 dbuf 问题——预防性升级，并非实际修复项。** ZFS 2.2.3 包含多个 dbuf 路径的修复，
包括 `dbuf_hold()` 错误处理中的锁泄漏
（[PR #15644](https://github.com/openzfs/zfs/pull/15644)）。这些修复是否直接对应
`dbuf_hold_impl → dmu_read_uio_dbuf → zfs_read` 这条读路径的崩溃，仍无法确认——
没有找到明确针对该调用链的 PR，系统此后的持续稳定也并不依赖这次 ZFS 升级。
ZFS 仍然升级到了 2.2.10，纯粹是作为纵深防御手段。

每次崩溃的触发条件都相同：对 ZFS 文件系统的持续并发读取——这正是 CPU 电压不稳定
以"ZFS 崩溃"的表象暴露出来的原因。

- **Trilium Notes** — 笔记服务的 SQLite 数据库存放在 ZFS 上，频繁的后台并发读请求
- **本机编译** — 编译过程中读取大量源码文件，编译中止
- **DKMS 内核模块构建** — 后台编译读取 ZFS 源码文件

这也是修复工作必须在**云端 GitHub Actions 上**完成的原因：每一次尝试在本机编译都以
崩溃告终，无法在问题内部解决问题。

## 3. 为什么是 2.2.10？

该 bug 在任何 ≥ 2.2.3 的版本中都已修复。选择 2.2.10 而非更高版本，有三点考量：

**留在 2.2.x 分支，不跳 2.3.x 或 2.4.x。** Ubuntu 24.04 的 `zfs-initramfs` 启动脚本、
pool 缓存格式和 feature flags 均基于 2.2.x 开发。跳到 2.4.x 会引入不必要的风险：上游
`openzfs-zfs-initramfs` 2.4.x 的启动架构已经变化，需要更大范围的 initramfs 改造。
Ubuntu 24.04 LTS 也只会持续维护 2.2.x 的安全补丁。

**2.2.10 是截至 2026 年 7 月 2.2.x 的最新版本。** 取最新补丁版本，
一次性获得 2.2.3 以来所有修复——不只是 use-after-free，还包括其他读路径稳定性改进。

**pool feature 兼容性。** ZFS pool 携带 feature flags 版本号。留在 2.2.x 意味着
pool 与 Ubuntu 原生 ZFS 保持兼容，万一需要回滚仍然可读。若执行 `zpool upgrade` 升到
2.4.x 特性，pool 将对 2.2.x 不可读——不可逆。

## 4. 为什么升级内核或 `apt upgrade` 都没用？

### 升级内核无效

这是最自然的第一反应——但行不通。Ubuntu 24.04 的 **ZFS 版本与内核版本解耦**。
内核模块存放在 `linux-modules-extra-<kver>` 这个独立的包里，Ubuntu 单独构建并冻结。
即使通过 HWE 升级到更新的内核（如 6.11.x），其中的 ZFS 模块仍然是 2.2.2——
Ubuntu 在整个 24.04 LTS 生命周期内就是这样打包的。升级内核改变的是模块运行的 ABI，
而不是 ZFS 版本本身。

### `apt upgrade` 同样无解

`zfsutils-linux` 及相关库包在 Ubuntu 24.04 的软件源里被固定在 2.2.2，Noble pocket
中没有更新版本，`apt` 根本没有可用更新。

正式的升级路径是等待 Ubuntu 26.04（内置 ZFS 2.4.1），但该升级通道要等到 26.04.1 发布
后才开放（预计 2026 年 8 月左右）。我们需要立即修复。

## 5. 在 GitHub Actions 上编译 ZFS 2.2.10

在本机编译 ZFS 会通过有 bug 的 ZFS 读取源码文件，从而触发我们想要修复的 bug，
因此使用 GitHub Actions 进行交叉编译。

### 5.1 关键构建要点

- 目标内核：`6.8.0-134-generic`（必须精确匹配）
- 输出 `.deb` 包便于安装
- 通过 DKMS 编译内核模块
- **将 `.ko` 压缩为 `.ko.zst`** — Ubuntu 24.04 使用 zstd 压缩的内核模块；未压缩的 `.ko`
  文件会被 `dracut-install` 在构建 initramfs 时静默跳过

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

完整 workflow 见 [github.com/Oseenix/zfs-build](https://github.com/Oseenix/zfs-build)。

## 6. 安装包

> **前置条件——先关闭 Secure Boot。**
> 本方案编译的内核模块**未经 Ubuntu 内核签名密钥签名**。Secure Boot 开启时，
> 内核会拒绝加载未签名模块，开机进入 busybox 并报
> `Failed to load ZFS modules`——无论其他步骤是否正确。
> 请在 UEFI 固件设置中关闭 Secure Boot 后再继续。
> 若需保持 Secure Boot 开启，可通过自定义 MOK（Machine Owner Key）对模块签名，
> 该过程不在本文讨论范围。

下载 artifact 后安装。这些包与 Ubuntu 原生的 `zfsutils-linux` 系列冲突，
需要加 `--force-conflicts`：

> **安装前**：先创建递归 ZFS 快照作为回滚点。
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

## 7. initramfs 深坑

真正的麻烦从这里开始。安装并重启后：

```text
Failed to load ZFS modules.
Manually load the modules and exit.
```

进入 busybox。三个问题相互叠加。

### 7.1 问题一：未压缩的 `.ko` 被 initramfs 忽略

上游 `openzfs-zfs-initramfs` 包在内部使用 `dracut-install` 将内核模块复制进 initramfs。
Ubuntu 24.04 的所有内核模块使用 `.ko.zst`（zstd 压缩），`dracut-install` 会静默跳过
未压缩的 `.ko` 文件。

**修复**：在 GitHub Actions workflow 中打包前先压缩模块（见上方 `zstd -19` 步骤）。

### 7.2 问题二：`modules.dep` 未更新

即使模块已正确压缩，安装后仍需运行 `depmod` 将其注册到 `modules.dep`。
否则 initramfs 内部的 `modprobe zfs` 会静默失败。

```bash
sudo depmod -a 6.8.0-134-generic
grep "zfs\|spl" /usr/lib/modules/6.8.0-134-generic/modules.dep
# 应输出：
# updates/dkms/spl.ko.zst:
# updates/dkms/zfs.ko.zst: updates/dkms/spl.ko.zst
```

再重新生成 initramfs：

```bash
sudo update-initramfs -u -k 6.8.0-134-generic
```

验证模块已打进新 initramfs：

```bash
lsinitramfs /boot/initrd.img-6.8.0-134-generic | grep "zfs.ko"
# 应输出：usr/lib/modules/6.8.0-134-generic/updates/dkms/zfs.ko.zst
```

### 7.3 问题三：LUKS Keystore 解锁逻辑缺失

Ubuntu 24.04 的 ZFS 加密采用双层结构：

```mermaid
flowchart TD
    A[GRUB] --> B[initramfs]
    B --> C[modprobe zfs]
    C --> D[zpool import rpool -N]
    D --> E[/dev/zvol/rpool/keystore 出现]
    E --> F[cryptsetup luksOpen\nPlymouth 密码提示界面]
    F --> G[挂载 /dev/mapper/keystore-rpool\n→ /run/keystore/rpool/]
    G --> H[zfs load-key rpool\n读取 system.key]
    H --> I[挂载 rpool/ROOT/ubuntu_*\n→ /root]
    I --> J[pivot_root — 启动完成]
```

上游 `openzfs-zfs-initramfs` 2.2.10 包提供的 `scripts/zfs` 其实支持 ZFS 原生加密
（`decrypt_fs()` 会通过 Plymouth 弹出密码提示并调用 `zfs load-key`）——但它**完全不认识
Ubuntu 的 LUKS keystore 这一层**：它根本不会去找 `keystore` zvol，在这套方案下只会
一直卡在等一把它永远拿不到的密钥。

Ubuntu 自己的 `zfs-initramfs` 包含一个定制的 `scripts/zfs`，其中有完整的 keystore
解锁流程。由于 `openzfs-zfs-initramfs` 替换了 `zfs-initramfs`，这部分逻辑随之丢失。

**修复**：从正常工作的 6.8.0-124-generic initramfs 中提取 Ubuntu 定制版 `scripts/zfs`，
用于 6.8.0-134-generic 的 initramfs：

```bash
# 提取工作正常的 initramfs
mkdir /tmp/ie124 && unmkinitramfs /boot/initrd.img-6.8.0-124-generic /tmp/ie124

# 用 Ubuntu 定制版替换上游脚本
sudo cp /tmp/ie124/main/scripts/zfs /usr/share/initramfs-tools/scripts/zfs

# 重新生成
sudo update-initramfs -u -k 6.8.0-134-generic
```

Ubuntu 定制版中新增的 keystore 扫描代码（约第 976 行）：

```sh
# 为所有使用 keystore 的 pool 打开并挂载 LUKS
CRYPTROOT=/scripts/local-top/cryptroot
if [ -x "${CRYPTROOT}" ]; then
    TABFILE=/cryptroot/crypttab
    :>"${TABFILE}"
    # 等待 keystore zvol 设备出现
    NUMKS=$(zfs list -H -o name | grep '/keystore$' | wc -l)
    while [ ${NUMKS} -ne $(find /dev/zvol/ -name 'keystore' | wc -l) ]; do
        sleep .1
    done
    # 写临时 crypttab 并调用 cryptroot（弹出 Plymouth 密码界面）
    for ks in $(find /dev/zvol/ -name 'keystore'); do
        pool="$(basename $(dirname ${ks}))"
        echo "keystore-${pool} ${ks} none luks,discard" >> "${TABFILE}"
    done
    ${CRYPTROOT}
    # 挂载解锁后的 keystore 卷
    for dev in $(find /dev/mapper -name 'keystore-*'); do
        storepath="/run/$(echo $(basename ${dev})|sed -e 's,-,/,')"
        mkdir -p "${storepath}"
        mount "${dev}" "${storepath}"
    done
fi
```

此外，`mount_fs` 函数中还会调用 `decrypt_fs`，在 keyfile 可访问后触发 `zfs load-key`。

## 8. 验证

所有修复完成后重启：

```bash
uname -r
# 6.8.0-134-generic

zfs version
# zfs-2.2.10-1
# zfs-kmod-2.2.10-1
```

开机自动弹出 Plymouth LUKS 密码输入界面，输入一次密码，系统完全自动启动。

## 9. 到底坏在哪（速查表）

| 层级         | 问题                                                  | 修复                                                       | 状态         |
| ------------ | ----------------------------------------------------- | ------------------------------------------------------------ | ------------ |
| CPU / BIOS   | Vmin Shift Instability——未打微码补丁的 Raptor Lake     | 升级 BIOS 至 V17.I                                            | 已确认根因   |
| ZFS 内核模块 | 2.2.2 存在 `dbuf_hold_impl` use-after-free（相关性未确认） | 在 GitHub Actions 上编译 2.2.10                               | 预防性措施   |
| 模块打包     | `.ko` 未压缩为 `.ko.zst`                               | CI 中添加 `zstd -19` 压缩步骤                                 | 升级的前提   |
| `modules.dep` | 安装后未更新                                          | 执行 `depmod -a` + `update-initramfs`                         | 必需         |
| initramfs 脚本 | 上游 `openzfs-zfs-initramfs` 不支持 LUKS keystore    | 从 124-generic initramfs 复制 Ubuntu 定制版 `scripts/zfs`     | 必需         |

## 10. 关于 Ubuntu 26.04 的说明

Ubuntu 26.04 官方内置 ZFS 2.4.1。正确的长期解决方案是等待 24.04 → 26.04
的升级通道开放后升级（预计 26.04.1 发布后，约 2026 年 8 月）。
在此之前，上述方案可保持系统稳定运行。**不要执行 `zpool upgrade`**——
一旦需要回滚，会导致 pool 与 ZFS 2.2.x 不兼容。

## 11. 这件事到底是关于什么

BIOS 升级之后过去了三周，这台机器没有再崩过——同样的 Trilium 后台读取和本机编译
负载，以前几小时内必崩，现在没有再出现。ZFS 升级最终没有得到验证，只是作为额外
保障留着。

值得留下的四件事，没有一件真的跟 ZFS 有关：

- **panic 发生位置 ≠ 根因。** 每次崩溃都能对上 `dbuf_hold_impl → dmu_read_uio_dbuf →
  zfs_read` 调用链，甚至能在上游找到对应编号的 PR，这正是它有误导性的地方。真正的
  信号是每次堆栈上面那行 `mce: [Hardware Error]`，被忽视了好几周，因为这条指向
  ZFS 的堆栈看起来更像一个正经的软件 bug。一颗有问题的 CPU 造成的内存错误，会在
  内核接下来恰好碰到那块内存的任何子系统里冒出来，很难和该子系统自身的 bug 区分开。
- **绕开冻结又被 bug 卡住的包：去机外交叉编译。** Ubuntu 24.04 把 ZFS 版本和内核版本
  解耦冻结在 2.2.2，`apt` 在下一个 LTS 之前拿不到更新版本，本机编译还会重新触发要
  修的这个 bug。用 GitHub Actions 编译、force-install 装回去，这套路适用于其他被
  发行版冻结、又带着已知 bug 的包，不止 ZFS。
- **厂商上游包和发行版实际行为不是一回事。** OpenZFS 自己打的 `openzfs-zfs-initramfs`
  deb 包，不包含 Ubuntu 下游 fork 里那套 LUKS keystore 解锁逻辑——上游和发行版实际
  在跑的东西之间，存在一段双方都没有文档记载的差异。
- **13/14 代 Intel 桌面 CPU 出现莫名崩溃，先查 BIOS 微码。** Vmin Shift Instability
  这个 bug 比它牵连到的大多数软件栈都要更早存在。
