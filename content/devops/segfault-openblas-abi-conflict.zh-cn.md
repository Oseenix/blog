---
title: "排查 Numpy/SciPy 段错误：Conda+Poetry 引发 OpenBLAS ILP64/LP64 冲突"
description: "Numpy (PyPI, ILP64) 与 SciPy (conda-forge, LP64) 同时加载两套 OpenBLAS，导致 glibc free() 段错误。从 dmesg 到 GDB core dump 完整排查，最终迁移 Pixi 根治。"
categories:
  - DevOps
tags: [post-mortem, segfault, python, numpy, scipy, openblas, ABI, ILP64, LP64, conda, poetry, pixi, pip, gdb, core-dump, manylinux]
date: 2026-03-02
toc: true
draft: false
type: posts
author: Jinze Zhou
---

## 问题现象

WavePy 是一个基于 Python 3.12 的海洋波浪数据处理系统，运行在 Conda 环境 `wave312` 中。近期新版本开发过程出现进程无预警消失——没有 Python Traceback，没有错误日志，进程直接蒸发。

运行日志的最后一行始终停留在 `scipy.interpolate.griddata` 的内存监控输出上：

```text
2026-03-02 01:23:43,251 - MemoryMonitor - INFO - [MEM][interpolate_unstruct_grid:hsig:20260302_060000] RSS: 1440.44 MB
```

此后再无任何输出。没有 traceback，没有异常——典型的 C 扩展段错误（Segmentation Fault）。

## 初步分析

### 1. 内核日志确认崩溃类型

先确认：进程是被 OOM Killer 杀的，还是段错误？两个方向完全不一样。

```bash
journalctl -k --since "2026-03-01" | grep -iE "oom|kill|segfault"
```

内核日志（完整时间线）：

```text
Mar 01 14:58:06 python[489815]:  segfault at ffffffffffffffff in libc.so.6[...+188000] error 5 likely on CPU 10 (core 20)
Mar 01 15:03:12 python[535366]:  segfault at ffffffffffffffff in libc.so.6[...+188000] error 5 likely on CPU 9  (core 16)
Mar 01 15:09:22 wavepy[431967]: segfault at ffffffffffffffff in libc.so.6[...+188000] error 5 likely on CPU 10 (core 20)
Mar 01 15:58:26 wavepy[549459]: segfault at ffffffffffffffff in libc.so.6[...+188000] error 5 likely on CPU 11 (core 20)
Mar 01 15:59:57 python[648065]:  segfault at ffffffffffffffff in libc.so.6[...+188000] error 5 likely on CPU 8  (core 16)
Mar 01 16:00:05 python[648520]:  segfault at ffffffffffffffff in libc.so.6[...+188000] error 5 likely on CPU 8  (core 16)
Mar 01 16:00:23 python[649146]:  segfault at ffffffffffffffff in libc.so.6[...+188000] error 5 likely on CPU 8  (core 16)
Mar 01 16:00:51 wavepy[646001]: segfault at ffffffffffffffff in libc.so.6[...+188000] error 5 likely on CPU 10 (core 20)
Mar 01 16:01:12 python[650638]:  segfault at ffffffffffffffff in libc.so.6[...+188000] error 5 likely on CPU 8  (core 16)
Mar 01 16:01:38 wavepy[650592]: segfault at ffffffffffffffff in libc.so.6[...+188000] error 5 likely on CPU 11 (core 20)
Mar 01 17:57:14 wavepy[871486]: segfault at ffffffffffffffff in libc.so.6[...+188000] error 5 likely on CPU 8  (core 16)
Mar 01 17:58:12 wavepy[889435]: segfault at ffffffffffffffff in libc.so.6[...+188000] error 5 likely on CPU 0  (core 0)
Mar 01 18:00:38 wavepy[888255]: segfault at ffffffffffffffff in libc.so.6[...+188000] error 5 likely on CPU 8  (core 16)
Mar 01 20:16:44 wavepy[890230]: segfault at ffffffffffffffff in libc.so.6[...+188000] error 5 likely on CPU 10 (core 20)
Mar 01 22:29:06 python[1390552]: segfault at ffffffffffffffff in libc.so.6[...+188000] error 5 likely on CPU 10 (core 20)
Mar 01 22:46:42 wavepy[1139540]:segfault at ffffffffffffffff in libc.so.6[...+188000] error 5 likely on CPU 11 (core 20)
Mar 01 22:52:20 python[1422115]: segfault at ffffffffffffffff in libc.so.6[...+188000] error 5 likely on CPU 8  (core 16)
Mar 01 23:06:41 wavepy[1415857]:segfault at ffffffffffffffff in libc.so.6[...+188000] error 5 likely on CPU 9  (core 16)
Mar 01 23:31:58 wavepy[1495359]:segfault at ffffffffffffffff in libc.so.6[...+188000] error 5 likely on CPU 11 (core 20)
Mar 02 00:45:31 python[1678413]: segfault at ffffffffffffffff in libc.so.6[...+188000] error 5 likely on CPU 8  (core 16)
Mar 02 00:45:40 python[1678999]: segfault at ffffffffffffffff in libc.so.6[...+188000] error 5 likely on CPU 10 (core 20)
Mar 02 01:23:44 wavepy[1594473]: segfault at 75cd55573605   ip 000075cd55573605                       error 14 likely on CPU 11 (core 20)
```

**分析**：

- **约 20 次崩溃**，跨越多个不同 PID 的 `wavepy` 和 `python` 进程
- 前 21 条全部是 `error 5`（用户态读取不可访问的页），崩溃地址均为 `0xffffffffffffffff`
- 最后一条是 `error 14`（从非法地址取指令），崩溃地址 `75cd55573605` 看起来像损坏的函数指针
- 崩溃集中在 CPU core 16 和 core 20，暗示与特定的线程绑定有关
- 没有任何 OOM Killer 记录——排除内存溢出

### 2. 核心转储确认

查看 core dump，用于 GDB 分析要用。

```bash
cat /proc/sys/kernel/core_pattern
# /var/dumps/core_%e.%p.%h.%t

ls -la /var/dumps/core_wavepy.* | tail -10
```

```text
-rw------- 1 jerry jerry  2874966016 Mar  1 15:09 core_wavepy.431967.mdl.1772330962
-rw------- 1 jerry jerry  2766782464 Mar  1 15:58 core_wavepy.549459.mdl.1772333906
-rw------- 1 jerry jerry  2844991488 Mar  1 16:00 core_wavepy.646001.mdl.1772334051
-rw------- 1 jerry jerry  2640805888 Mar  1 16:01 core_wavepy.650592.mdl.1772334098
-rw------- 1 jerry jerry  2591006720 Mar  1 17:57 core_wavepy.871486.mdl.1772341034
-rw------- 1 jerry jerry  2785624064 Mar  1 18:00 core_wavepy.888255.mdl.1772341238
-rw------- 1 jerry jerry  2590007296 Mar  1 17:58 core_wavepy.889435.mdl.1772341092
-rw------- 1 jerry jerry  5879025664 Mar  1 20:16 core_wavepy.890230.mdl.1772349404
```

## 逐步排查

### 3. C 扩展包来源审查

WavePy 用了 Conda + Poetry 两套包管理器，引入了很多有C扩展的包，在这个问题分析完就可以看到这个混用容易引起问题。
因为出错log说明错误很可能和scipy及numpy有关，所以先看看 numpy 和 scipy 到底从哪装的：

```bash
conda list -n wave312 | grep -E "scipy|numpy|cfgrib|eccodes|rasterio|tiledb"
```

```text
cfgrib      0.9.15.1                 pypi_0    pypi
eccodes     2.46.0                   pypi_0    pypi
numpy       2.4.1                    pypi_0    pypi        ← ！来自 PyPI
rasterio    1.4.3                    pypi_0    pypi
scipy       1.17.0          py312h54fa4ab_1    conda-forge ← 来自 conda-forge
tiledb      0.35.2                   pypi_0    pypi
```

**发现关键疑点**：`numpy 2.4.1` 来自 PyPI，`scipy 1.17.0` 来自 conda-forge。尽管 `env.yaml` 中明确指定了 `numpy=2.3.*` 从 conda-forge 安装，但实际环境中 numpy 被 PyPI 版本覆盖了。

### 4. BLAS 配置检查

崩溃点在 `scipy.interpolate.griddata`——重度依赖线性代数运算，底层走 BLAS 接口。numpy 和 scipy 都依赖 BLAS 作为核心计算引擎，而 PyPI wheel 会把编译好的 BLAS 捆绑在 `*.libs/` 里分发，conda-forge 的包则用环境中共享的 BLAS。两边来源不同，链接的 BLAS 很可能不是同一个构建。

先看看 numpy 实际链接的是什么：

```bash
conda run -n wave312 python -c "import numpy as np; np.show_config()"
```

```text
Build Dependencies:
  blas:
    name: scipy-openblas
    openblas configuration: OpenBLAS 0.3.30 USE64BITINT DYNAMIC_ARCH NO_AFFINITY Haswell MAX_THREADS=64
    lib directory: .../scipy_openblas64/lib
```

关键信息：`USE64BITINT` —— 这是 **ILP64** 模式，使用 64 位整数作为 BLAS 接口的参数类型。

### 5. 进程内存映射——确认冲突

numpy 用了 ILP64 的 OpenBLAS，那 scipy 呢？最直接的办法：import 两个包，看进程实际加载了哪些动态库：

```bash
conda run -n wave312 python -c "
import numpy, scipy
with open('/proc/self/maps') as f:
    for line in f:
        if any(k in line for k in ['openblas', 'gfortran', 'quadmath']):
            print(line.strip())
"
```

```text
.../numpy.libs/libscipy_openblas64_-fdde5778.so
.../numpy.libs/libgfortran-040039e1-0352e75f.so.5.0.0
.../numpy.libs/libquadmath-96973f99-934c22de.so.0.0.0
.../scipy.libs/libscipy_openblas-6cdc3b4a.so
.../scipy.libs/libgfortran-8f1e9814.so.5.0.0
.../scipy.libs/libquadmath-828275a7.so.0.0.0
```

两套完全独立的 C 运行时同时存在于一个进程中：

| 包 | 库文件 | 整数位宽 |
|----|--------|----------|
| numpy (PyPI) | `libscipy_openblas64_-fdde5778.so` | **ILP64**（64 位） |
| scipy (conda) | `libscipy_openblas-6cdc3b4a.so` | **LP64**（32 位） |

文件名中的 `openblas64` vs `openblas`——后缀 `64` 即代表 ILP64 构建。不光是 OpenBLAS，连 libgfortran 和 libquadmath 也各自加载了两份。六个库在同一个进程里打架。

### 6. GDB 核心转储分析——还原崩溃现场

用GDB看core dump 崩溃时的调用栈：

```bash
gdb -batch \
  -ex "thread 1" \
  -ex "bt 30" \
  .../wave312/bin/python /var/dumps/core_wavepy.890230.mdl.1772349404
```

```text
Core was generated by `/home/jerry/miniconda3/envs/wave312/bin/python /home/jerry/miniconda3/envs/wave'.
Program terminated with signal SIGSEGV, Segmentation fault.

#0  0x000074c2dec36d75 in __GI___libc_free (mem=0x7) at ./malloc/malloc.c:3375
#1  0x000074c26b2426b7 in ?? () from .../psycopg2_binary.libs/libldap-1accf1ee.so.2.0.200
#2  0x000074c2deec60f2 in _dl_call_fini (closure_map=0x6315256ab770) at ./elf/dl-call_fini.c:43
#3  0x000074c2deeca578 in _dl_fini () at ./elf/dl-fini.c:114
#4  0x000074c2debd0a76 in __run_exit_handlers (status=0) at ./stdlib/exit.c:108
#5  0x000074c2debd0bbe in __GI_exit (status=0) at ./stdlib/exit.c:138
#6  0x00006314fc51c2d8 in Py_Exit (sts=0) at Python/pylifecycle.c:3199
#7  0x00006314fc519589 in handle_system_exit () at Python/pythonrun.c:777
```

**分析**：

- 崩溃点：`__GI___libc_free(mem=0x7)`——传入 `free()` 的指针是 `0x7`，这是一个明显非法的堆地址
- 崩溃指令：`mov rax, [rdi-0x8]`（机器码 `48 8b 47 f8`）—— glibc 在 `free()` 中读取 malloc chunk 头部，`rdi=0x7`，`rdi-8` 下溢到 `0xffffffffffffffff`
- 调用链：`Py_Exit` → `_dl_fini`（动态链接器清理）→ psycopg2 的 `libldap` → `free()`
- 这说明堆的破坏发生在**更早的时间点**（scipy 插值计算期间），但直到进程退出阶段 libldap 调用 `free()` 时才触发段错误

同一份 core dump 的 `info sharedlib` 也确认了崩溃进程加载了上一步发现的那六个冲突库。

### 7. 追溯依赖链——为什么 numpy 被覆盖

接下来追：到底是哪个 pip 包把 conda 装的 numpy 给覆盖了？

```bash
conda run -n wave312 pip show rio-tiler | grep Requires
conda run -n wave312 pip show rasterio | grep Requires
conda run -n wave312 pip show matplotlib | grep Requires
```

```text
rio-tiler:   Requires: ..., numpy, rasterio, ...
rasterio:    Requires: ..., numpy, ...
matplotlib:  Requires: ..., numpy, ...
```

**依赖链还原**：

```text
poetry install
  → rio-tiler (非 optional，从 PyPI 安装)
    → 依赖 numpy → pip 解析到 PyPI 上的 numpy 2.4.1
    → 依赖 rasterio → 也依赖 numpy
  → matplotlib (非 optional，从 PyPI 安装)
    → 依赖 numpy
  → pip 将 conda-forge 的 numpy 2.3.x 升级为 PyPI 的 numpy 2.4.1
```

`pyproject.toml` 中 numpy 标记为 `optional = true`，但 rio-tiler、rasterio、matplotlib 是**非 optional** 的，它们的传递依赖绕过了 optional 标记，pip 直接从 PyPI 拉取了 numpy。

## 根因定位

问题的根源是 **ILP64 与 LP64 OpenBLAS 的 ABI 冲突**，由 Conda + PyPI 混合安装引入。

### 崩溃机制详解

1. **双库加载**：进程启动后，numpy 的 `import` 加载了 `libscipy_openblas64`（ILP64），scipy 的 `import` 加载了 `libscipy_openblas`（LP64）。两个库在进程地址空间中共存。

2. **全局状态冲突**：OpenBLAS 内部使用全局变量管理线程池和内存分配器。两个版本的全局符号可能互相覆盖（取决于动态链接器的符号解析顺序），导致一个版本的代码使用另一个版本的全局状态。

3. **整数位宽错配**：当 scipy 的 `griddata` 调用 Qhull/LAPACK 进行三角剖分和插值时，BLAS 调用可能被路由到 ILP64 版本的实现。ILP64 期望 64 位整数参数，但接收到的是 LP64 传入的 32 位整数——高 32 位是未初始化的栈垃圾。这导致 BLAS 内核将随机值解释为数组长度，触发大规模的内存越界读写。

4. **堆元数据破坏**：越界写入破坏了 glibc malloc 的 chunk 头部（存储在每个分配块前 8 字节）。损坏可能在数秒到数分钟内不被察觉——直到某次 `free()` 调用尝试读取损坏的 chunk 头部时触发段错误。

5. **崩溃时刻**：在本案例中，堆损坏发生在 `interpolate_unstruct_grid` 的 scipy 计算期间，但段错误延迟到进程退出阶段——`_dl_fini` 调用 psycopg2 的 `libldap` 析构函数，`libldap` 内部的 `free()` 命中了损坏的 chunk 头部。

### 崩溃特征总结

| 特征 | 值 | 含义 |
|------|-----|------|
| 崩溃指令 | `48 8b 47 f8`（`mov rax, [rdi-0x8]`） | glibc `free()` 读取 malloc chunk 的 `size` 字段 |
| 报错地址 | `0xffffffffffffffff` | `rdi=0x7`，`rdi-8` 整数下溢到 `-1` |
| error code | 5 | 用户态读取不可访问页面 |
| error code | 14（最后一次） | 从非法地址取指令（函数指针损坏） |
| 高频 CPU | core 16, core 20 | OpenBLAS 工作线程绑定的核心 |

### 间歇性原因

堆损坏是否触发段错误取决于：
- 内存分配/释放的时序——损坏的 chunk 何时被 `free()` 触及
- OpenBLAS 线程池的调度——`MAX_THREADS=64` 加上 SWAN 的 12 个 OMP 线程，线程竞争加剧冲突概率
- `griddata` 的输入规模——1440MB RSS 下的大规模三角剖分增加了 BLAS 调用频率

## 解决方案

### 传统修复（Conda + Poetry 工作流）

在保留 Conda + Poetry 双包管理器架构的前提下，需要严格的 6 步安装流程：

```bash
# 1. 创建 Conda 环境（安装 C 扩展包）
conda env create -f env.yaml
# 2. 激活环境
conda activate wave312
# 3. 让 Poetry 直接安装到 Conda 环境（而非创建独立 venv）
poetry config virtualenvs.create false --local
# 4. 安装纯 Python 依赖（此步会通过传递依赖从 PyPI 覆盖 numpy）
poetry install
# 5. 清理 pip eccodes 捆绑的 C 库（libopenjp2 冲突源）
pip uninstall -y eccodes eccodeslib eckitlib fckitlib findlibs 2>/dev/null
# 6. 重钉 C 扩展包（必须是最后一步）
conda install -n wave312 -c conda-forge numpy scipy python-eccodes cfgrib
```

**关键约束**：步骤 6 必须是最后一步。此后不能再运行 `poetry install`，否则 PyPI 的 numpy 会再次覆盖 conda 版本。如果只需重装 wavepy 本身（改了代码），使用 `pip install -e . --no-deps`。

这个方案有效但脆弱——任何一次 `poetry install` 都会重新引入冲突，需要再次执行步骤 5-6。

### 根治方案：迁移到 Pixi

**Pixi** 是 prefix.dev（mamba 团队）做的新包管理器，设计上就不可能出现我们碰到的问题：

1. **统一依赖解析**：Pixi 先解析所有 conda 依赖，再在 conda 环境的约束下解析 PyPI 依赖。不存在「pip 覆盖 conda 包」的可能。
2. **单一锁文件**：`pixi.lock` 同时锁定 conda 和 PyPI 包版本，替代了 `conda-lock.yml` + `poetry.lock` 的分裂状态。
3. **项目级环境**：环境与项目绑定（`.pixi/envs/`），不是全局共享的 conda 环境。

迁移后的安装流程：

```bash
pixi install   # 一步完成，替代上面的 6 步
pixi run wavepy # 运行
pixi run test   # 测试
```

**验证结果**：

```text
# numpy 来自 conda-forge，无捆绑 OpenBLAS
numpy.libs/  → 不存在 ✓
scipy.libs/  → 不存在 ✓
eccodeslib   → 未安装 ✓

# BLAS 配置：共享单一实例
numpy show_config() →
  blas: name=blas, lib directory=.pixi/envs/default/lib, version=3.9.0
```

导致段错误的三个条件（ILP64/LP64 双 OpenBLAS、libopenjp2 三重加载、84 个捆绑 C 库），在 Pixi 环境中压根不会出现。
---

## 后续发现：libopenjp2 三重加载崩溃

修复 OpenBLAS 冲突后，系统恢复运行。但在约 12 小时后，出现了一个**新的段错误**，崩溃点不再是 `libc.so.6`，而是 `libopenjp2.so.7`（JPEG2000 编解码库）。

### 崩溃现场

```text
wavepy[3267456]: segfault at 10 ip 00007b12f0d062c3 sp 00007b122cecba70 error 4
  in libopenjp2.so.7[7b12f0cdc000+4f000] likely on CPU 10 (core 20, socket 0)
```

这次崩溃的特征和之前不一样：

| 特征 | OpenBLAS 崩溃 | libopenjp2 崩溃 |
|------|--------------|----------------|
| 崩溃库 | `libc.so.6`（`free()`） | `libopenjp2.so.7` |
| 崩溃地址 | `0xffffffffffffffff` | `0x10`（近 NULL） |
| error code | 5（读保护页） | 4（读不存在页） |
| 来源 | OpenBLAS ABI 冲突 | libopenjp2 多版本冲突 |

### 进程内存映射审查

同样的套路——先看进程内存映射里有没有多版本冲突：

```bash
cat /proc/<pid>/maps | grep libopenjp2
```

```text
# eccodeslib（pip）捆绑的 libopenjp2 — 崩溃发生在这里
.../eccodeslib/lib64/libopenjp2.so.7

# rasterio（pip）捆绑的 libopenjp2 — 版本 2.4.0
.../rasterio.libs/libopenjp2-rasterio-a166e295.so.2.4.0

# pillow（pip）捆绑的 libopenjp2 — 版本 2.5.4
.../pillow.libs/libopenjp2-94e588ba.so.2.5.4
```

**三个不同版本的 libopenjp2** 同时加载在同一个进程中。又是一样的故事。

### pip 捆绑库全景

进一步审查发现，pip 安装的 manylinux wheel 包总共在进程中加载了 **84 个捆绑 C 库**，多个库存在版本冲突：

| 重复库 | 副本数 | 来源 |
|--------|--------|------|
| libopenjp2 | 3 | eccodeslib, rasterio, pillow |
| libgeos | 3 | conda 系统, rasterio (3.11.1), shapely (3.13.1) |
| libcrypto/libssl | 4 | conda 系统, eccodeslib (1.1.1k), psycopg2 (3.x), rasterio (1.1) |
| libldap | 3 | conda 系统, eccodeslib, psycopg2_binary |
| libtiff | 3 | pillow, rasterio, pyproj |
| libcurl | 3 | eccodeslib, rasterio, pyproj |

这些重复的 C 库各自带有不同的版本号和 ABI，在同一进程地址空间中共存，随时可能触发与 OpenBLAS 相同的符号冲突和堆损坏。

### libopenjp2 崩溃的依赖链

追一下 eccodeslib 的依赖链，看它怎么混进来的：

```bash
pip show cfgrib | grep Requires    # → eccodes
pip show eccodes | grep Requires   # → eccodeslib
pip show eccodeslib | grep Requires # → eckitlib, fckitlib
```

```text
pyproject.toml: cfgrib = ">=0.9.10" (非 optional)
  → poetry install
    → pip install cfgrib
      → 依赖 eccodes (pip Python 封装)
        → 依赖 eccodeslib (pip, 捆绑 eccodes C 库 + libopenjp2.so.7)
          → 依赖 eckitlib (pip, 捆绑 libcurl, libcrypto, libldap 等 26 个 C 库)
```

和 numpy 那次一模一样：非 optional 的传递依赖拉进了捆绑 C 库的 pip 包，和 conda 环境里的系统库打架。

### 内核连锁崩溃（附带发现）

libopenjp2 段错误还触发了一个 **Ubuntu 6.8.0-101 内核 bug**：UBSAN（未定义行为检测器）在 `printk_ringbuffer.c` 中检测到位移溢出，随后 `vsnprintf` 在尝试格式化错误消息时自身发生了页错误，导致内核 Oops：

```text
UBSAN: shift-out-of-bounds in /build/linux-AJr2Xq/linux-6.8.0/kernel/printk/printk_ringbuffer.c:370:27
BUG: unable to handle page fault for address: 0000000080000041
Oops: 0000 [#1] PREEMPT SMP NOPTI
note: wavepy[3267456] exited with irqs disabled
note: wavepy[3267456] exited with preempt_count 1
```

这是一个内核自身的 bug，不是 wavepy 的问题。但它说明用户态的段错误可以级联触发内核层面的异常，增加了排查的复杂度。

### 完整修复方案

最终方案是迁移到 Pixi，在 `pyproject.toml` 中统一管理 conda 和 PyPI 依赖：

```toml
# pyproject.toml（关键部分）
[tool.pixi.workspace]
channels = ["conda-forge"]
platforms = ["linux-64"]
channel-priority = "strict"

[tool.pixi.dependencies]
numpy = ">=2.3"              # MUST be conda (OpenBLAS)
scipy = "1.17.*"             # MUST be conda (OpenBLAS)
eccodes = ">=2.20"           # MUST be conda (libopenjp2)
python-eccodes = ">=2.46"
cfgrib = ">=0.9.10"          # MUST be conda (eccodeslib)
rasterio = ">=1.4"           # MUST be conda (GDAL, libopenjp2)
matplotlib = ">=3.8"         # MUST be conda (transitive numpy)
# ... 其他 C 扩展包

[project.dependencies]  # 纯 Python 包，从 PyPI 安装
# rio-tiler, boto3, schedule, etc.
```

Pixi 的解析顺序保证 C 扩展包走 conda-forge（共享系统库），PyPI 包装不了也覆盖不了。

`env.yaml` 和 `poetry` 不再需要。安装只需 `pixi install`。

## 经验总结

1. **Conda + pip 混着用迟早出事**。pip 的传递依赖会悄悄覆盖 conda 装的包，你根本不会注意到。numpy、scipy 这种底层库，必须在 pip install 之后用 conda 重新钉死。

2. **API 一样不代表 ABI 一样**。PyPI 的 numpy 2.4.1 和 conda 的 2.3.x，Python 层面完全兼容，`import numpy` 也不报错。但底层链接的 OpenBLAS 整数位宽不同——只有跑到大规模 BLAS 计算时才会炸。

3. **manylinux wheel 的捆绑库在 conda 环境里是祸根**。pip wheel 把 C 依赖打包在 `*.libs/` 下，单独用没问题。但在 conda 环境里，这些捆绑库和系统库共存于同一进程。我们这个环境里同时跑着 84 个捆绑 C 库，至少 6 组版本冲突——不崩才怪。

4. **堆坏了不一定马上崩**。scipy 算插值时破坏的堆，到进程退出 psycopg2 的 libldap 调 `free()` 才炸。如果盯着 psycopg2 查就完全跑偏了。

5. **Python 的日志和异常在段错误面前没用**。能靠的只有 `dmesg`/`journalctl`、`ldd`、`gdb`、`/proc/<pid>/maps` 这些底层工具。

6. **生产环境一定要开 core dump**。配好 `core_pattern`，留够磁盘空间。这次全靠 `/var/dumps/` 下的 core 文件，在 GDB 里直接看到了双 OpenBLAS 加载和 libldap 析构触发点。

7. **修 bug 不如让 bug 没法出现**。6 步 re-pin 流程能用，但每次 `poetry install` 又会打回原形。换到 Pixi 之后，「 pip 覆盖 conda 包」这事从根上就不可能发生了。

