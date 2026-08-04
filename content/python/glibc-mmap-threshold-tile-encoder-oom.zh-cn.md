---
title: "452 MB 且还在涨：WavePy OOM 背后的第二个 glibc malloc bug"
description: "三个 WavePy 编码进程在 20-30GB 处被 OOM Kill，尽管代码里每处理完一个 tile 就 del + gc.collect() 一次。Python 堆很干净。真正的元凶是 glibc 自适应 mmap 阈值，悄悄把逐 tile 的 numpy buffer 路由到一块永远不还给系统的堆上——跟上一篇文章里的 MALLOC_ARENA_MAX 修复是完全不同的机制，却藏在同样一句“每次都 del+gc.collect() 了，应该没问题”的代码模式背后。"
categories:
  - Python
tags: [python, glibc, malloc, mmap, M_MMAP_THRESHOLD, memory, OOM, xarray, zarr, dask, numpy, debugging, wavepy, MALLOC_ARENA_MAX, malloc_trim]
date: 2026-08-04
toc: true
draft: false
type: posts
author: Jinze Zhou
---

## 先说结论

三个长时间运行的编码进程在 20-30GB 处被 OOM Kill，尽管每完成一个工作单元都照例
`del` + `gc.collect()` 一次。Python 堆很干净——泄漏在低一层，出在 glibc 的分配器里。
glibc 默认不用固定的 `mmap` 阈值，而是每次释放一块大的 `mmap` 分配后就把阈值往上调，
预期接下来还会有类似大小的分配。对于反复分配、释放许多*大小不一*、生命周期短、
几 MB 量级 buffer 的工作负载来说，这个预期不成立：分配会被逐渐降级到一块不把页面
还给操作系统的堆 arena 上。修复只需要一行——`mallopt(M_MMAP_THRESHOLD, N)` 把阈值
固定下来，并且关闭自适应行为，固定到进程结束。图片 tile、视频帧、ML batch 都是
这类负载，不限于 Python。

## 机制：glibc 的自适应 mmap 阈值

这个站点[已经有一篇文章]({{< ref "python/thread-leak-asyncio-executor.zh-cn.md" >}})讲过 glibc malloc 把一个 WavePy 进程活活吃掉——164 个每线程 arena，用 `MALLOC_ARENA_MAX=4` 修复的。这次是*不同*的机制，打在*不同*的代码路径上，用的是*同一个*分配器。

glibc 的 `malloc()` 有两种方式满足请求：

- **低于 mmap 阈值**——从某个 arena 的 `brk`/`sbrk` 堆里切出来。`free()` 把这块 chunk 放进该 arena 内部的空闲链表，供*同一个 arena* 内部复用。这些页面会一直保持常驻（计入 RSS），直到有东西去清理堆顶（`malloc_trim`），或者同一个 arena 里另一次分配正好复用到那块空间。
- **高于 mmap 阈值**——由它自己独立的 `mmap()` 区域提供服务。`free()` 会立刻 `munmap()` 它——内存无条件归还给操作系统，不涉及任何空闲链表记账。

这里每个 tile、每个时次解码出来的 numpy buffer 大小落在 1-5MB 区间——远高于 glibc *默认* 的 128KB 阈值，朴素地想，它们本该已经走 mmap 路径、干净地还回去了。实际没有，因为还差一环：**默认情况下 glibc 用的不是固定阈值，而是自适应的**。每次一块大的 `mmap` 分配被释放，glibc 都会根据这块的大小把阈值往上调（64 位系统上最高到 32MB），逻辑是：一个曾经需要过大 buffer 的工作负载，很可能很快还会需要差不多大小的，不如复用 arena 空间，省下 mmap/munmap 这对系统调用。这个赌注对很多工作负载是合理的。但对"扫描许多不同的 tile，每个产生几个 MB 量级、用一次就扔掉的 buffer"这种模式来说，是*最糟糕*的赌注——阈值在每次释放后持续走高，越来越多这种一次性分配被降级到 brk 堆上，在那里 `free()` 不再意味着"还回去"。

## 只测 `malloc_trim()`：基本没用

第一个直觉是在每个 tile 后调一次 `malloc_trim(0)`，因为它就是专门设计来把释放的页面还给操作系统的：

```text
                    不加 malloc_trim      每个 tile 后加 malloc_trim(0)
tile 19 RSS:        451.7 MB              409.8 MB   (-9%)
```

有点改善，但远不是修复。`malloc_trim` 只能释放每个 arena 里**堆顶**的连续空闲区域——也就是"荒野边界"。哪怕只有一个很小的、还存活的分配挡在一大块已释放区域的上方，下面的部分就全部被钉住；`malloc_trim` 没法绕过它做压缩。几十个大小各不相同的 tile buffer 交错分配、释放，恰好会把堆碎片化成让堆顶清理完全失效的形状。

## 修复：把 mmap 阈值钉死

`mallopt(M_MMAP_THRESHOLD, N)` 做两件事：设置阈值本身，外加一个 glibc 文档明确记载的副作用——只要调用过它，自适应调整就会被**关闭**，阈值从此固定在 `N`，不会再在运行期间被动态上调。跟 `MALLOC_ARENA_MAX` 不一样，这不是一个只在初始化时生效的开关；它在每次 `malloc()` 调用时都会被读取，所以完全可以在解释器启动之后、从 Python 侧设置——不需要动 `pixi.toml` 的环境变量：

```python
# src/wavepy/wavepy.py —— 进程入口，任何 encode 工作开始之前
try:
    _libc = ctypes.CDLL('libc.so.6')
    _M_MMAP_THRESHOLD = -3  # glibc mallopt() 参数 id，见 malloc.h
    _libc.mallopt(_M_MMAP_THRESHOLD, 64 * 1024)
except OSError:
    pass  # 非 glibc/Linux 平台（如本地 macOS 开发机）静默跳过，只是优化
```

64KB，舒适地低于这个工作负载实际产生的约 1-5MB 单 tile buffer，所以它们会稳定地走 mmap 路径，不受 glibc 自适应逻辑原本会做出的决定影响。

## 验证

同样的 20-tile、5×5 区域复现实验，加上修复：

```text
tile 0  (x=0,y=0): RSS = 198.5 MB
tile 4  (x=4,y=0): RSS = 231.1 MB
tile 9  (x=4,y=1): RSS = 258.4 MB
tile 14 (x=4,y=2): RSS = 257.9 MB
tile 19 (x=4,y=3): RSS = 262.1 MB
```

262.1MB，对比未修复的 451.7MB——降低 42%——更关键的是，曲线从第 9 个 tile 起**走平**了，而不是继续无界攀升。这个形状上的变化比百分比数字更重要：无界攀升的曲线不管机器多大最终都会 OOM；平台期不会，不管真实任务要扫多少个 tile。

我通过真实的生产入口（`import wavepy.wavepy`，而不是在测试脚本里手动调 `mallopt()`）重新跑了一遍复现实验，确认这个修复在真实调用路径下也确实生效，不只是我隔离测试里的效果：

```text
基线（import wavepy.wavepy 之后）: 272.5 MB
20 个 tile 后的最终 RSS：          396.3 MB   (+123.8 MB，未修复时对比约 +327 MB)
```

走真实代码路径，增长量少了 62%。之后跑了全量回归：481 个测试，跟基线一致的 10 个既存失败，零新增失败。

## 两个不同的 bug，同一个分配器

值得明确说一下这跟[上一篇 arena 文章]({{< ref "python/thread-leak-asyncio-executor.zh-cn.md" >}})的关系，因为从外部看两个症状几乎一模一样（"RSS 持续增长，Python 堆看起来很干净"）：

```text
                    MALLOC_ARENA_MAX bug              M_MMAP_THRESHOLD bug
触发条件            大量线程，每个都拿到               许多大小不一、生命周期
                    自己的 arena                       很短的 buffer 落在同一
                                                        个 arena 上
出现位置            每次 handler 调用的                EncodePNG 逐 tile 抓取
                    asyncio.run() / ThreadPoolExecutor  循环
glibc 的行为        每个抢到未加锁 mutex 的线程          每次大块释放后持续调高
                    都新建一个 64MB 的 arena             mmap 切分阈值，把后续
                                                          分配降级到 brk 堆上
修复方式            MALLOC_ARENA_MAX=4（环境变量，       mallopt(M_MMAP_THRESHOLD,
                    必须在 glibc 初始化前设置）           N)（运行时调用，热循环
                                                          开始前任意时刻均可）
修复位置            pixi.toml [tasks].start.env          wavepy.py，Python 侧
```

同一个分配器，两个独立的开关，两个独立的 bug，在同一个代码库里相隔五个月分别被发现。`malloc_trim(0)` 对两者都有一点点帮助，但只是缓解手段——不能替代真正去调对每个 bug 实际涉及的那个开关。

## 收获

- 只能看到 Python 堆的 profiler（`tracemalloc`、`pympler`）对这整一类 bug 是盲的——不管是这次这个，还是上一篇文章里的 arena 那个，都活在 C 分配器这一层，比 Python 堆低一层。能看到它们的是 `/proc/PID/status` 的 `VmRSS` 和 `/proc/PID/smaps`。
- `resource.getrusage().ru_maxrss` 是历史峰值，不是当前用量——它不可能变小，用它去判断某次 `del` 有没有释放内存只会得到错误的答案。
- 在每个 tile 边界虔诚地执行 `del` + `gc.collect()` 是必要的，但不充分。它正确地丢弃了 Python 引用；底层 C 分配器要不要把页面还给操作系统是另一个问题，glibc 根据分配大小和它自己的自适应启发式规则来回答，跟你的 Python 代码写得多规范无关。
- 两个 RSS 膨胀的 bug，同一个根因类别（glibc ptmalloc），同样的"Python 侧看起来完全干净"症状，不同的修复方式。当你已经修好了一个 glibc malloc 开关，而 RSS 还在别的地方继续异常时，不要假设这是同一个 bug 换了张脸——先确认这次实际涉及的是哪个开关，再决定要不要照搬上次的修复。

## 附录：这个 bug 是怎么被找到的

上面是可迁移的机制、修复和收获。下面是在一个具体代码库里定位到这个 bug 的排查
过程——只想要能迁移的部分的话，到这里可以停了。

### 症状

某个长时间运行的服务把大型格点数据渲染成图片 tile。渲染一个完整区域——几十个 tile 乘以若干变量乘以一整轮时序时次——跑在单次、长时间运行的 `EncodePNG.encode()` 调用里，每个批处理周期启动一个全新的 Python 进程。

内核 OOM killer 在 4 分钟窗口内连续杀掉了三个这样的进程，同时还搭上了几个 Chrome 标签页和一个 VS Code 实例——都在跟同一台机器抢内存：

```text
10:56:16  Killed chrome (pid 1425825)
10:56:16  Killed chrome (pid 361803)
10:56:16  Killed code/VSCode (pid 1630443)
10:56:20  Killed python/WavePy (pid 1739797)  anon-rss ≈ 20.8 GB
10:58:33  Killed python/WavePy (pid 1742268)  anon-rss ≈ 30.0 GB
11:00:04  Killed python/WavePy (pid 1744230)  anon-rss ≈ 30.0 GB
```

三个不同的 PID，三次独立的 encode 调用，在内核出手前各自都爬到了 20-30GB 区间。不是单个进程失控——是一个*模式*。

### 先排除显而易见的可能

第一个怀疑是重试循环：某处崩溃后立刻重启，内存在多次重启间累积。`crontab -l` 查不到任何相关条目，`journalctl -k` 在 11:00:04 之后也没有新的 kill 记录——这是一次性事件，三个真实的并行批处理任务撞上了本就内存紧张的机器，不是自动化脚本的 bug。这条路很快排除；真正的问题是：为什么单单**一次** `EncodePNG.encode()` 调用就要吃掉 20-30GB。

### 先读代码

`encode_png.py` 里 `process_global_tiles`——处理大多数变量的兜底主路径——已经在做教科书式的正确操作：

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

一个 tile 的数据进来，编码，删除，垃圾回收，下一个 tile。`TileProcessor.process_tile_data` 和 `encode_png_date` 在更细的粒度上做了同样的事——每个变量、每个时次的**每一个 tile** 之后都 `del` + `gc.collect()`。这在命令式 Python 里已经是内存意识拉满的写法了。结果还是在 30GB 处被 OOM。

不管问题出在哪，肯定不是漏写了某个 `del`。

### 先测量，别猜：`ru_maxrss` 的坑

第一反应是在循环里用 `resource.getrusage(resource.RUSAGE_SELF).ru_maxrss` 在每次 tile 抓取前后打点。数字看起来不对——明明 `gc.collect()` 应该释放了真实内存，delta 却经常读到 `0.0`。`ru_maxrss` 是**历史峰值**，不是当前用量——它在进程生命周期内只会单调不减。用一个结构上不可能变小的值去判断"这次 del 到底有没有真的释放内存"，等于什么也没测出来。

换成 `/proc/self/status` 的 `VmRSS`——内核对常驻内存的实时视角——画面立刻就清楚了。

```python
def rss_mb():
    with open('/proc/self/status') as f:
        for line in f:
            if line.startswith('VmRSS:'):
                return int(line.split()[1]) / 1024
```

### 定位真实的数据源

大多数变量的兜底数据源是一个 zarr 存储，由内部客户端的 `LocalClient.create()` / `.append(append_dim="time")` 按时次逐步写入。真实周期下：

```text
维度:      {time: 129, lat: 721, lon: 1440}
变量:      var_a, var_b, var_c, var_d, var_e
每变量分块: lat: (181, 181, 181, 178), lon: (720, 720), time: (1, 1, ..., 1)
磁盘大小(压缩后): 1.4 GB
完全物化后:       2.68 GB
```

每个 chunk 大约覆盖*全球纬度范围的四分之一、经度范围的一半*——比 `process_global_tiles` 实际查询的 256×256 像素 tile 粗得多。每个 tile 每个时次每个变量都至少要碰到一整块 chunk，所以每次 `get_data_with_latlons()` 调用必然读得比 tile 需要的更多。这是读放大，而且是真实存在的——但放大本身解释不了跨越许多*小的*、各自都被释放掉的读取时出现的无界增长。"释放之后"的某个环节没有表现得像真正被释放了。

### 复现增长曲线

我写了一个最小循环，精确匹配 `_get_tile_data` 的调用模式——主数据源查询（`method='nearest'`）、extend/兜底数据源查询（`method='linear'`）、像真实抽取步骤那样强制物化，然后 `del` + `gc.collect()`，跟生产代码一模一样：

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

124.6MB 的基线，扫完一个 *5×5 的小区域* 之后涨到 451.7MB——还不是全球范围，不是所有变量，只是一个区域的主数据源+extend 查询。`del` 和 `gc.collect()` 每一轮都跑了，对增长曲线基本没有任何遏制作用。

### 排除泄漏的可能

在归咎于分配器之前，得先排除一个更简单的解释：某处持有了我没找到的引用——未关闭的 dataset、不断增长的缓存、xarray 的文件句柄 LRU。测试方法：连续查询**完全相同的 tile** 十次，而不是十个不同的 tile。

```text
iter 0: RSS = 213.5 MB, gc objects: 136672, file_cache: 0
iter 5: RSS = 218.7 MB, gc objects: 137054, file_cache: 0
iter 9: RSS = 223.1 MB, gc objects: 137054, file_cache: 0
```

平的。对象数量很快封顶，`xarray.backends.file_manager.FILE_CACHE` 全程保持为空（没有任何东西在多次调用之间被遗留打开），RSS 在几轮之内就稳定下来。不是经典意义上的泄漏——20 个*不同* tile 那个测试里的增长，跟触碰到的*不同* chunk 数量成正比，一旦某个 chunk 的字节已经常驻，释放掉再重新拉取同一个不会产生任何新增开销。也就是说，那些不同 chunk 读取所分配的内存，是真的没有还回来——即便已经 `del` + `gc.collect()` 了。

### 没有修的部分

排查过程中还发现了两个真实存在、但不属于这次"内存安全修复"范畴的问题：

- `process_global_tiles` 是**逐 tile**重新查询主数据源和 extend 数据源的。`process_regular_tiles` 和 `process_unstructured_tiles` 已经是把整个区域的数据**只拉一次**，再从内存里切出各个 tile。让 `process_global_tiles` 向这个模式看齐，大概率能进一步降低读放大，但会改变峰值内存的形状（从许多小的 tile 尺寸分配变成一次大的区域尺寸分配），这值得单独测量评估，不适合跟分配器调优的修复捆在一起做。
- `gc.collect()` 目前在字面意义上的每个 tile、每个时次之后都被调用，分布在好几处。它本身无害，但对这两个 glibc bug 都没有任何帮助——循环引用垃圾回收和把页面还给操作系统是完全不相关的两套机制。现阶段它纯粹是叠加在真正修复之上的 CPU 开销。
