---
title: "Debugging Numpy/SciPy Segfaults: OpenBLAS ILP64/LP64 Conflict via Conda+Poetry"
description: "Numpy (PyPI, ILP64) and SciPy (conda-forge, LP64) loading two sets of OpenBLAS led to a glibc free() segfault. A full walkthrough from dmesg to GDB core dumps, and how switching to Pixi fixed it for good."
categories:
  - DevOps
tags: [post-mortem, segfault, python, numpy, scipy, openblas, ABI, ILP64, LP64, conda, poetry, pixi, pip, gdb, core-dump, manylinux]
date: 2026-03-02
toc: true
draft: false
type: posts
author: Jinze Zhou
---

## The Symptoms

WavePy is a Python 3.12-based ocean wave data processing system running in a Conda environment called `wave312`. During recent development, the process started vanishing without warning. No Python traceback, no error logs, just gone.

The last line of the log always stopped at the memory monitor output for `scipy.interpolate.griddata`:

```text
2026-03-02 01:23:43,251 - MemoryMonitor - INFO - [MEM][interpolate_unstruct_grid:hsig:20260302_060000] RSS: 1440.44 MB
```

After that, nothing. No traceback, no exception. It was a classic C extension segfault.

## Preliminary Analysis

### 1. Checking Kernel Logs

First question: was this OOM or a segfault? Completely different directions.

```bash
journalctl -k --since "2026-03-01" | grep -iE "oom|kill|segfault"
```

Kernel logs (full timeline):

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

**Analysis**:
- About 20 crashes across different PIDs for `wavepy` and `python`.
- The first 21 entries are all `error 5` (user-mode read of an inaccessible page). The crash address is always `0xffffffffffffffff`.
- The last one is `error 14` (instruction fetch from an invalid address). The address `75cd55573605` looks like a corrupted function pointer.
- Crashes are clustered on CPU cores 16 and 20, which suggests something related to specific thread bindings.
- No OOM Killer records. We can rule out memory exhaustion.

### 2. Core Dump Confirmation

I checked the core dumps for GDB analysis.

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

## Step-by-Step Troubleshooting

### 3. Auditing C Extension Sources

WavePy uses both Conda and Poetry. This mix introduces a lot of packages with C extensions, which turned out to be the problem.
The logs pointed toward SciPy and Numpy, so I checked where they were actually coming from:

```bash
conda list -n wave312 | grep -E "scipy|numpy|cfgrib|eccodes|rasterio|tiledb"
```

```text
cfgrib      0.9.15.1                 pypi_0    pypi
eccodes     2.46.0                   pypi_0    pypi
numpy       2.4.1                    pypi_0    pypi        ← ! from PyPI
rasterio    1.4.3                    pypi_0    pypi
scipy       1.17.0          py312h54fa4ab_1    conda-forge ← from conda-forge
tiledb      0.35.2                   pypi_0    pypi
```

**Found a red flag**: `numpy 2.4.1` is from PyPI, while `scipy 1.17.0` is from conda-forge. Even though `env.yaml` specified `numpy=2.3.*` from conda-forge, the PyPI version overrode it.

### 4. BLAS Configuration Check

The crash happens in `scipy.interpolate.griddata`, which does heavy linear algebra under the hood. That means BLAS. Numpy and SciPy both rely on BLAS as their engine. PyPI wheels bundle their own BLAS in `*.libs/`, while conda-forge packages use the shared BLAS in the environment. Since they came from different sources, they probably weren't using the same build.

I checked what Numpy was actually linked to:

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

Key info: `USE64BITINT`. This is **ILP64** mode, which uses 64-bit integers for BLAS interface parameters.

### 5. Process Memory Mapping: Confirming the Conflict

Numpy is using ILP64 OpenBLAS. What about SciPy? The easiest way to check is to import both and see which dynamic libraries the process actually loads:

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

Two completely independent C runtimes living in the same process:

| Package | Library File | Integer Width |
|----|--------|----------|
| numpy (PyPI) | `libscipy_openblas64_-fdde5778.so` | **ILP64** (64-bit) |
| scipy (conda) | `libscipy_openblas-6cdc3b4a.so` | **LP64** (32-bit) |

The filenames `openblas64` vs `openblas` tell the story. The `64` suffix means an ILP64 build. It's not just OpenBLAS either. Both `libgfortran` and `libquadmath` were loaded twice. Six libraries duking it out in the same process. Not exactly a healthy situation.

### 6. GDB Core Dump Analysis: Reconstructing the Crash

I pulled up the call stack from the core dump:

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

**Analysis**:

- Crash point: `__GI___libc_free(mem=0x7)`. The pointer passed to `free()` was `0x7`, which is obviously an invalid heap address.
- Crash instruction: `mov rax, [rdi-0x8]` (machine code `48 8b 47 f8`). glibc is trying to read the malloc chunk header. With `rdi=0x7`, `rdi-8` underflows to `0xffffffffffffffff`.
- Call chain: `Py_Exit` -> `_dl_fini` (dynamic linker cleanup) -> psycopg2's `libldap` -> `free()`.
- This means the heap corruption happened **much earlier**, likely during the SciPy interpolation. It just didn't trigger a segfault until the process tried to exit and `libldap` called `free()`.

The `info sharedlib` command in GDB confirmed those six conflicting libraries were all present in the crashing process.

### 7. Tracing the Dependency Chain: Why was Numpy Overridden?

I needed to find out which pip package pulled in the PyPI version of Numpy.

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

**Dependency Chain**:

```text
poetry install
  → rio-tiler (not optional, installed from PyPI)
    → depends on numpy → pip resolves to numpy 2.4.1 on PyPI
    → depends on rasterio → also depends on numpy
  → matplotlib (not optional, installed from PyPI)
    → depends on numpy
  → pip upgrades conda-forge's numpy 2.3.x to PyPI's numpy 2.4.1
```

Numpy was marked as `optional = true` in `pyproject.toml`, but `rio-tiler`, `rasterio`, and `matplotlib` were **not** optional. Their transitive dependencies bypassed the optional flag, and pip just grabbed Numpy from PyPI.

## Root Cause Analysis

The root cause was an **ABI conflict between ILP64 and LP64 OpenBLAS**, introduced by mixing Conda and PyPI.

### How it Crashed

1. **Dual Library Loading**: The process loaded `libscipy_openblas64` (ILP64) for Numpy and `libscipy_openblas` (LP64) for SciPy. Both lived in the same address space.

2. **Global State Conflict**: OpenBLAS uses global variables for thread pools and memory allocation. Depending on the symbol resolution order, one version might use the other's global state.

3. **Integer Width Mismatch**: When SciPy's `griddata` calls Qhull or LAPACK, the BLAS call might get routed to the ILP64 implementation. ILP64 expects 64-bit integers, but it gets 32-bit integers from the LP64 caller. The upper 32 bits are just uninitialized stack garbage. The BLAS kernel interprets this random value as an array length, leading to massive out-of-bounds reads and writes.

4. **Heap Metadata Corruption**: These out-of-bounds writes trash the glibc malloc chunk headers (the 8 bytes before every allocated block). This corruption can sit there silently for seconds or minutes.

5. **The Crash**: In this case, the heap was trashed during the SciPy calculation, but the segfault waited until exit. `_dl_fini` called the `libldap` destructor, and its internal `free()` hit the corrupted header.

### Crash Signature Summary

| Feature | Value | Meaning |
|------|-----|------|
| Crash Instruction | `48 8b 47 f8` (`mov rax, [rdi-0x8]`) | glibc `free()` reading malloc chunk `size` field |
| Error Address | `0xffffffffffffffff` | `rdi=0x7`, `rdi-8` integer underflow to `-1` |
| Error Code | 5 | User-mode read of inaccessible page |
| Error Code | 14 (last one) | Instruction fetch from invalid address (corrupted function pointer) |
| High-freq CPU | core 16, core 20 | Cores bound to OpenBLAS worker threads |

### Why was it Intermittent?

Whether heap corruption triggers a segfault depends on:
- Timing. When does `free()` actually touch the corrupted chunk?
- Thread pool scheduling. `MAX_THREADS=64` plus 12 OMP threads in SWAN made the race conditions worse.
- Input size. Large-scale triangulation at 1440MB RSS increased the frequency of BLAS calls.

## Solution

### The Traditional Fix (Conda + Poetry Workflow)

If you want to keep both package managers, you need a strict six-step process:

```bash
# 1. Create Conda environment (install C extension packages)
conda env create -f env.yaml
# 2. Activate environment
conda activate wave312
# 3. Tell Poetry to install directly into the Conda environment
poetry config virtualenvs.create false --local
# 4. Install pure Python dependencies (this step will override numpy via transitive deps)
poetry install
# 5. Clean up C libraries bundled with pip eccodes (libopenjp2 conflict source)
pip uninstall -y eccodes eccodeslib eckitlib fckitlib findlibs 2>/dev/null
# 6. Re-pin C extension packages (must be the last step)
conda install -n wave312 -c conda-forge numpy scipy python-eccodes cfgrib
```

**The Catch**: Step 6 has to be last. If you run `poetry install` again, PyPI's Numpy will just override it again. If you only need to reinstall the code itself, use `pip install -e . --no-deps`.

This works, but it's fragile. One wrong command and you're back to square one.

### The Real Fix: Migrating to Pixi

**Pixi** is a new package manager from prefix.dev (the mamba team). It's designed to avoid this exact mess:

1. **Unified Resolution**: Pixi resolves Conda dependencies first, then resolves PyPI dependencies within those constraints. Pip can't override Conda packages.
2. **Single Lockfile**: `pixi.lock` handles both Conda and PyPI, replacing the split `conda-lock.yml` and `poetry.lock`.
3. **Project-level Environments**: Environments are tied to the project in `.pixi/envs/`, not shared globally.

The new workflow:

```bash
pixi install   # One step replaces the six steps above
pixi run wavepy # Run
pixi run test   # Test
```

**Verification**:

```text
# numpy from conda-forge, no bundled OpenBLAS
numpy.libs/  → does not exist ✓
scipy.libs/  → does not exist ✓
eccodeslib   → not installed ✓

# BLAS config: single shared instance
numpy show_config() →
  blas: name=blas, lib directory=.pixi/envs/default/lib, version=3.9.0
```

The conditions that caused the segfault (dual OpenBLAS, triple libopenjp2, 84 bundled C libraries) simply don't exist in the Pixi environment.

---

## Follow-up Discovery: Triple libopenjp2 Crash

After fixing the OpenBLAS conflict, the system was stable for about 12 hours. Then a **new segfault** appeared. This time it wasn't in `libc.so.6`, but in `libopenjp2.so.7` (a JPEG2000 library).

### The New Crash

```text
wavepy[3267456]: segfault at 10 ip 00007b12f0d062c3 sp 00007b122cecba70 error 4
  in libopenjp2.so.7[7b12f0cdc000+4f000] likely on CPU 10 (core 20, socket 0)
```

This one looked different:

| Feature | OpenBLAS Crash | libopenjp2 Crash |
|------|--------------|----------------|
| Crashing Library | `libc.so.6` (`free()`) | `libopenjp2.so.7` |
| Error Address | `0xffffffffffffffff` | `0x10` (near NULL) |
| Error Code | 5 (read protected page) | 4 (read non-existent page) |
| Source | OpenBLAS ABI conflict | libopenjp2 version conflict |

### Memory Map Audit

Same trick. I checked the memory map for conflicts:

```bash
cat /proc/<pid>/maps | grep libopenjp2
```

```text
# libopenjp2 bundled with eccodeslib (pip). Crash happened here.
.../eccodeslib/lib64/libopenjp2.so.7

# libopenjp2 bundled with rasterio (pip). Version 2.4.0.
.../rasterio.libs/libopenjp2-rasterio-a166e295.so.2.4.0

# libopenjp2 bundled with pillow (pip). Version 2.5.4.
.../pillow.libs/libopenjp2-94e588ba.so.2.5.4
```

**Three different versions of libopenjp2** loaded at once. Same story, different library.

### The Big Picture of Bundled Libraries

I dug deeper and found that pip's manylinux wheels had loaded **84 bundled C libraries** into the process. Many had version conflicts:

| Duplicate Library | Copies | Source |
|--------|--------|------|
| libopenjp2 | 3 | eccodeslib, rasterio, pillow |
| libgeos | 3 | conda system, rasterio (3.11.1), shapely (3.13.1) |
| libcrypto/libssl | 4 | conda system, eccodeslib (1.1.1k), psycopg2 (3.x), rasterio (1.1) |
| libldap | 3 | conda system, eccodeslib, psycopg2_binary |
| libtiff | 3 | pillow, rasterio, pyproj |
| libcurl | 3 | eccodeslib, rasterio, pyproj |

These duplicate libraries each have their own versions and ABIs. They're just waiting to trigger another symbol conflict or heap corruption.

### The libopenjp2 Dependency Chain

I traced how `eccodeslib` got in:

```bash
pip show cfgrib | grep Requires    # → eccodes
pip show eccodes | grep Requires   # → eccodeslib
pip show eccodeslib | grep Requires # → eckitlib, fckitlib
```

```text
pyproject.toml: cfgrib = ">=0.9.10" (not optional)
  → poetry install
    → pip install cfgrib
      → depends on eccodes (pip Python wrapper)
        → depends on eccodeslib (pip, bundles eccodes C library + libopenjp2.so.7)
          → depends on eckitlib (pip, bundles 26 C libraries including libcurl, libcrypto, libldap)
```

It's the same pattern. A non-optional transitive dependency pulled in a pip package with bundled C libraries that fought with the system libraries in the Conda environment.

### Cascading Kernel Crash (Side Note)

The libopenjp2 segfault actually triggered a **bug in the Ubuntu 6.8.0-101 kernel**. UBSAN detected a shift-out-of-bounds in the printk buffer, and then `vsnprintf` hit a page fault while trying to format the error message. This led to a kernel Oops.

```text
UBSAN: shift-out-of-bounds in /build/linux-AJr2Xq/linux-6.8.0/kernel/printk/printk_ringbuffer.c:370:27
BUG: unable to handle page fault for address: 0000000080000041
Oops: 0000 [#1] PREEMPT SMP NOPTI
note: wavepy[3267456] exited with irqs disabled
note: wavepy[3267456] exited with preempt_count 1
```

This was a kernel bug, not a WavePy bug, but it shows how a user-space segfault can spiral into kernel-level chaos, making debugging even harder.

### Final Fix

The final solution was moving to Pixi and managing everything in `pyproject.toml`:

```toml
# pyproject.toml (key parts)
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
# ... other C extension packages

[project.dependencies]  # Pure Python packages from PyPI
# rio-tiler, boto3, schedule, etc.
```

Pixi's resolution order ensures C extensions come from conda-forge and use shared system libraries. PyPI can't touch them.

`env.yaml` and `poetry` are gone. Now it's just `pixi install`.

## Lessons Learned

1. **Mixing Conda and pip is asking for trouble**. Pip's transitive dependencies will quietly override your Conda packages without you ever noticing. For low-level libraries like Numpy or SciPy, you have to re-pin them with Conda after any pip install.

2. **Same API doesn't mean same ABI**. Numpy 2.4.1 from PyPI and 2.3.x from Conda look the same to Python. `import numpy` works fine. But the underlying OpenBLAS integer widths are different. It only blows up when you hit heavy BLAS calculations.

3. **Bundled libraries in manylinux wheels are a nightmare in Conda environments**. Pip wheels bundle C dependencies in `*.libs/`. That's fine on its own, but in a Conda environment, they live alongside system libraries. We had 84 bundled libraries and at least 6 version conflicts. It was a miracle it ran at all.

4. **Heap corruption doesn't always crash right away**. The heap was trashed during SciPy's interpolation, but it didn't fail until `libldap` called `free()` during exit. If you're staring at psycopg2 trying to debug this, you're barking up the wrong tree.

5. **Python logs and exceptions are useless for segfaults**. You have to rely on low-level tools like `dmesg`, `ldd`, `gdb`, and `/proc/<pid>/maps`.

6. **Always enable core dumps in production**. Set up `core_pattern` and make sure you have disk space. The core files in `/var/dumps/` were the only reason I could see the dual OpenBLAS loading and the `libldap` trigger.

7. **Fix the system, not the bug**. The six-step re-pinning process worked, but it was easy to break. Switching to Pixi made it impossible for pip to override Conda packages in the first place.
