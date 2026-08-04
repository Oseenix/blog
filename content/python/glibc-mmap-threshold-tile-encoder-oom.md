---
title: "452 MB and Climbing: A Second glibc malloc Bug Behind WavePy's OOM Kills"
description: "Three WavePy encoder processes got OOM-killed at 20-30GB despite del + gc.collect() after every single tile. The Python heap was clean. The real culprit was glibc's adaptive mmap threshold silently routing per-tile numpy buffers onto a heap that never gives memory back -- a different mechanism from the MALLOC_ARENA_MAX fix in the previous post, hiding behind the exact same del+gc.collect() pattern that looked like it should have worked."
categories:
  - Python
tags: [python, glibc, malloc, mmap, M_MMAP_THRESHOLD, memory, OOM, xarray, zarr, dask, numpy, debugging, wavepy, MALLOC_ARENA_MAX, malloc_trim]
date: 2026-08-04
toc: true
draft: false
type: posts
author: Jinze Zhou
---

## TL;DR

Three long-running encoder processes got OOM-killed at 20-30 GB despite disciplined `del` +
`gc.collect()` after every single unit of work. The Python heap was clean — the leak was one
layer down, in glibc's allocator. By default glibc doesn't use a fixed `mmap` threshold; it
raises the threshold every time a large `mmap`'d chunk is freed, on the bet that a similarly
large allocation is coming again soon. For a workload that repeatedly allocates and frees many
*differently-sized*, short-lived, multi-megabyte buffers, that bet is wrong: allocations get
progressively demoted onto a heap arena that never gives pages back to the OS. The fix is one
line — `mallopt(M_MMAP_THRESHOLD, N)` pins the threshold and disables the adaptive behavior for
the rest of the process's life. This applies to any long-running process (Python or otherwise)
that cycles through many moderately-large, short-lived buffers — image tiles, video frames, ML
batches, whatever the buffers happen to be.

## The Mechanism: glibc's Adaptive mmap Threshold

This site [already has one post]({{< ref "python/thread-leak-asyncio-executor.md" >}}) about glibc malloc eating a WavePy process alive — 164 per-thread arenas, fixed with `MALLOC_ARENA_MAX=4`. This is a *different* mechanism, hitting a *different* code path, in the *same* allocator.

glibc's `malloc()` has two ways to satisfy a request:

- **Below the mmap threshold** — carved out of an arena's `brk`/`sbrk` heap. `free()` puts the chunk on a free list for reuse *within that arena*. The pages stay resident (counted in RSS) until something walks the top of the heap (`malloc_trim`) or another allocation in the same arena reuses that exact space.
- **Above the mmap threshold** — served by its own private `mmap()` region. `free()` `munmap()`s it immediately — the memory is unconditionally returned to the OS, no free-list bookkeeping involved.

The numpy buffers decoded per tile per timestep here land in the 1-5 MB range — comfortably above glibc's *default* 128 KB threshold, so in a naive mental model they should already be going through mmap and coming back cleanly. They weren't, because of one more piece: **by default, glibc doesn't use a fixed threshold — it's adaptive**. Every time a large `mmap`'d chunk is freed, glibc raises the threshold based on that chunk's size (up to 32 MB on 64-bit), on the theory that a workload which needed a large buffer once will probably need a similarly large one again soon, and reusing arena space avoids the mmap/munmap syscall pair. That's a reasonable bet for many workloads. It's the *worst possible* bet for scanning many different tiles, each producing a handful of megabyte-scale buffers used once and thrown away — the threshold keeps climbing after each free, progressively demoting more and more of these one-shot allocations onto the brk heap, where `free()` no longer means "give it back."

## Testing `malloc_trim()` Alone: Mostly Doesn't Help

The obvious first thing to try is calling `malloc_trim(0)` after each tile, since it's specifically designed to hand freed pages back to the OS:

```text
                    without malloc_trim   with malloc_trim(0) per tile
tile 19 RSS:        451.7 MB              409.8 MB   (-9%)
```

A small improvement, not a fix. `malloc_trim` can only release the **top-of-heap** contiguous free region in each arena — the "wilderness" at the frontier. If even one small, still-live allocation sits above a large freed region, everything below it is pinned; `malloc_trim` can't compact around it. With dozens of differently-sized tile buffers being allocated and freed in an interleaved sequence, the heap fragments in exactly the way that defeats top-of-heap trimming.

## The Fix: Pin the mmap Threshold

`mallopt(M_MMAP_THRESHOLD, N)` does two things: it sets the cutoff, and — per glibc's documented behavior — calling it at all **disables the dynamic adjustment**, so the threshold stays fixed at `N` for the rest of the process's life instead of creeping upward. Unlike `MALLOC_ARENA_MAX`, this isn't an initialization-time-only knob; it's read on every `malloc()` call, so it's safe to set from Python well after interpreter startup — no `pixi.toml` env-var plumbing required:

```python
# src/wavepy/wavepy.py — process entrypoint, before any encode work
try:
    _libc = ctypes.CDLL('libc.so.6')
    _M_MMAP_THRESHOLD = -3  # glibc mallopt() parameter id, see malloc.h
    _libc.mallopt(_M_MMAP_THRESHOLD, 64 * 1024)
except OSError:
    pass  # not glibc/Linux (e.g. local dev on macOS) -- optimization only
```

64 KB, comfortably below the ~1-5 MB per-tile buffers this workload actually produces, so they consistently route through mmap regardless of what glibc's adaptive logic would otherwise have decided.

## Verification

Same 20-tile, 5×5-region reproduction, with the fix in place:

```text
tile 0  (x=0,y=0): RSS = 198.5 MB
tile 4  (x=4,y=0): RSS = 231.1 MB
tile 9  (x=4,y=1): RSS = 258.4 MB
tile 14 (x=4,y=2): RSS = 257.9 MB
tile 19 (x=4,y=3): RSS = 262.1 MB
```

262.1 MB versus 451.7 MB unfixed — a 42% reduction — and critically, the curve **flattens** from tile 9 onward instead of climbing indefinitely. That shape change matters more than the percentage: an unbounded climb eventually OOMs no matter how large the box is; a plateau doesn't, regardless of how many tiles the real job scans.

I re-ran the reproduction through the actual production entrypoint (`import wavepy.wavepy`, not a manual `mallopt()` call in the test script) to confirm the fix is wired correctly for real invocations, not just my isolated test:

```text
baseline (post wavepy.wavepy import): 272.5 MB
final RSS after 20 tiles:             396.3 MB   (+123.8 MB, vs. +327 MB unfixed)
```

62% less growth through the real code path. Full regression suite afterward: 481 tests, the same 10 pre-existing baseline failures, zero new failures.

## Two Different Bugs, Same Allocator

Worth being explicit about how this relates to [the arena post]({{< ref "python/thread-leak-asyncio-executor.md" >}}), since both symptoms look identical from the outside ("RSS keeps growing, Python heap looks clean"):

```text
                    MALLOC_ARENA_MAX bug              M_MMAP_THRESHOLD bug
Trigger             many threads, each getting        many differently-sized,
                    its own arena                     short-lived buffers on
                                                        one arena
Where it lives      asyncio.run() / ThreadPoolExecutor  EncodePNG per-tile fetch
                    per handler invocation              loop
What glibc does     creates a new 64 MB arena per        keeps raising the mmap
                    unlocked-mutex thread                cutoff after every large
                                                          free, demoting future
                                                          allocations onto the
                                                          brk heap
Fix                 MALLOC_ARENA_MAX=4 (env var,        mallopt(M_MMAP_THRESHOLD,
                    must be set before glibc init)       N) (runtime call, any
                                                          time before the hot loop)
Fix location        pixi.toml [tasks].start.env          wavepy.py, Python-side
```

Same allocator, two independent knobs, two independent bugs, discovered five months apart in the same codebase. `malloc_trim(0)` helps both, marginally, but is a mitigation for either — not a substitute for addressing the actual knob each bug turns on.

## Takeaways

- A profiler that only sees the Python heap (`tracemalloc`, `pympler`) is blind to this entire class of bug — both this one and the arena one from the previous post live one layer below, in the C allocator. `/proc/PID/status`'s `VmRSS` and `/proc/PID/smaps` are the tools that see it.
- `resource.getrusage().ru_maxrss` is a high-water mark, not current usage — it cannot go down, and using it to check whether a `del` freed memory will lie to you.
- `del` + `gc.collect()` religiously applied at every tile boundary is necessary but not sufficient. It correctly drops the Python reference; whether the underlying C allocator gives the pages back to the OS is a separate question glibc answers based on allocation size and its own adaptive heuristics, not on how disciplined your Python code is.
- Two RSS-bloat bugs, same root cause category (glibc ptmalloc), same "the Python side looks perfectly clean" symptom, different fixes. When you've fixed one glibc malloc knob and RSS is *still* misbehaving somewhere else, don't assume it's the same bug wearing a different hat — check which knob is actually implicated before reapplying the last fix.

## Appendix: How This Was Found

Everything above is the transferable mechanism, fix, and lessons. Everything below is the
specific investigation trail that led there in one codebase — skip it unless you want the
blow-by-blow of ruling out the wrong hypotheses first.

### The Symptom

One long-running service renders large gridded datasets into image tiles. Rendering a full region — dozens of tiles times several variables times a full time-series worth of timesteps — runs inside a single long-lived `EncodePNG.encode()` call, in one Python process, launched fresh per batch cycle.

The kernel OOM killer took out three of these processes inside a four-minute window, alongside a couple of Chrome tabs and a VS Code instance competing for the same box's RAM:

```text
10:56:16  Killed chrome (pid 1425825)
10:56:16  Killed chrome (pid 361803)
10:56:16  Killed code/VSCode (pid 1630443)
10:56:20  Killed python/WavePy (pid 1739797)  anon-rss ≈ 20.8 GB
10:58:33  Killed python/WavePy (pid 1742268)  anon-rss ≈ 30.0 GB
11:00:04  Killed python/WavePy (pid 1744230)  anon-rss ≈ 30.0 GB
```

Three separate PIDs, three separate encode invocations, each independently climbing into the 20-30 GB range before the kernel stepped in. Not a single runaway process — a *pattern*.

### Ruling Out the Obvious

My first hypothesis was a retry loop: something crashing and immediately relaunching, compounding memory across restarts. `crontab -l` showed nothing relevant, and `journalctl -k` showed no repeat kills after 11:00:04 — the storm was a one-time event, three legitimate parallel batch jobs colliding with an already memory-constrained box, not an automation bug. Ruled out quickly; the real question was why a *single* `EncodePNG.encode()` invocation needs 20-30 GB in the first place.

### Reading the Code First

`encode_png.py`'s `process_global_tiles` — the fallback path used for most variables — already does the textbook-correct thing:

```python
# Process tiles sequentially to reduce memory
for x in range(config.xtiles):
    for y in range(config.ytiles):
        lons, lats, zr_dat, zr_dat_extend = self._get_tile_data(
            config, mapping, x, y, lat_length, epsg
        )
        try:
            zr_dir = self._extract_wave_features(
                config, var, mapping, lons, lats, zr_dat, zr_dat_extend
            )
            self.encode_png(zr_dir, var, config, x, y)
        finally:
            if "zr_dir" in locals():
                del zr_dir
            del zr_dat
            if zr_dat_extend is not None:
                del zr_dat_extend
            gc.collect()  # Force garbage collection
```

One tile's data in, encoded, deleted, garbage-collected, next tile. `TileProcessor.process_tile_data` and `encode_png_date` do the same thing at an even finer grain — `del` and `gc.collect()` after *every single tile*, for every variable, for every timestep. On paper this is about as memory-conscious as imperative Python gets. And it still OOM'd at 30 GB.

Whatever was wrong, it wasn't a missing `del`.

### Measuring, Not Guessing: the `ru_maxrss` Trap

My first instinct was to instrument a loop with `resource.getrusage(resource.RUSAGE_SELF).ru_maxrss` before and after each tile fetch. The numbers looked wrong — deltas often read `0.0` right after a `gc.collect()` that should have freed real memory. `ru_maxrss` is a **high-water mark**, not current usage — it never decreases for the life of the process. Measuring "did this `del` actually free memory" with a value that structurally can't go down was measuring nothing.

Switched to `/proc/self/status`'s `VmRSS` — the kernel's live view of resident memory — and the picture became legible immediately.

```python
def rss_mb():
    with open('/proc/self/status') as f:
        for line in f:
            if line.startswith('VmRSS:'):
                return int(line.split()[1]) / 1024
```

### Isolating the Real Store

The fallback data source for most variables is a zarr store, written incrementally per timestep by an internal client's `LocalClient.create()` / `.append(append_dim="time")`. On a real cycle:

```text
dims:  {time: 129, lat: 721, lon: 1440}
vars:  var_a, var_b, var_c, var_d, var_e
chunks (per var): lat: (181, 181, 181, 178), lon: (720, 720), time: (1, 1, ..., 1)
on-disk (compressed): 1.4 GB
fully materialized:   2.68 GB
```

Each chunk covers roughly a *quarter of the global latitude range and half the global longitude range* — hugely coarser than the 256×256-pixel tiles `process_global_tiles` actually queries. Every tile touches at least one full chunk per timestep per variable, so each `get_data_with_latlons()` call necessarily reads more than the tile needs. That's read amplification, and it's real — but amplification alone doesn't explain unbounded growth across many *small*, individually-freed reads. Something downstream of "freed" wasn't behaving like freed.

### Reproducing the Growth

I wrote a minimal loop matching `_get_tile_data`'s exact call pattern — primary fetch (`method='nearest'`), extend/fallback fetch (`method='linear'`), force materialization the way the real extraction step does, then `del` + `gc.collect()`, exactly like the production code:

```python
for i in range(20):
    x, y = i % xtiles, i // xtiles
    zr_dat = lc.get_data_with_latlons(fname, lats, lons)
    zr_dat_extend = lc.get_data_with_latlons(fname, lats, lons, method='linear')
    _ = {v: zr_dat[v].values for v in zr_dat.data_vars}
    _e = {v: zr_dat_extend[v].values for v in zr_dat_extend.data_vars}
    del zr_dat, zr_dat_extend, _, _e
    gc.collect()
```

```text
tile 0  (x=0,y=0): RSS = 223.1 MB
tile 4  (x=4,y=0): RSS = 262.0 MB
tile 9  (x=4,y=1): RSS = 409.1 MB
tile 14 (x=4,y=2): RSS = 417.7 MB
tile 19 (x=4,y=3): RSS = 451.7 MB
```

124.6 MB baseline to 451.7 MB after 20 tiles on a *5×5 region* — not the whole world, not all variables, just one region's primary + extend fetch. `del` and `gc.collect()` ran every single iteration and did essentially nothing to stop the climb.

### Ruling Out a Leak

Before blaming the allocator, I needed to rule out something simpler: a reference held somewhere I hadn't found — an unclosed dataset, a growing cache, xarray's file-handle LRU. The test: query the *exact same tile* ten times in a row instead of ten different tiles.

```text
iter 0: RSS = 213.5 MB, gc objects: 136672, file_cache: 0
iter 5: RSS = 218.7 MB, gc objects: 137054, file_cache: 0
iter 9: RSS = 223.1 MB, gc objects: 137054, file_cache: 0
```

Flat. Object count plateaus, `xarray.backends.file_manager.FILE_CACHE` stays empty the whole time (nothing was left open across calls), RSS stabilizes within a few iterations. No leak in the classic sense — the growth in the 20-*different*-tiles test was proportional to the number of *distinct* chunks touched, and once a chunk's bytes were resident, freeing and re-fetching the same one cost nothing new. Which meant the memory those distinct-chunk reads allocated genuinely wasn't coming back, even after `del` + `gc.collect()`.

### What I Didn't Fix

Two more things came up during this investigation that are real but out of scope for a memory-safety fix:

- `process_global_tiles` re-queries the primary and extend sources **per tile**. `process_regular_tiles` and `process_unstructured_tiles` already fetch their region's data **once** and slice tiles out of the in-memory result. Bringing `process_global_tiles` in line with that pattern would likely reduce read amplification further, but it changes the peak-memory shape (one big region-sized allocation instead of many small tile-sized ones) and deserves its own measurement pass rather than being bundled into an allocator-tuning fix.
- `gc.collect()` is called after literally every tile, every timestep, in multiple call sites. It's harmless but doesn't address either glibc bug — cyclic garbage collection and returning pages to the OS are unrelated mechanisms. Right now it's pure CPU overhead stacked on top of the actual fix.
