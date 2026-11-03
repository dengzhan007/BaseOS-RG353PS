# 启动耗时 — RG353PS

真机实测，2026-11-03（早期分段数据于 2026-11-02 采集）。每个版本取三次暖启动；改动
U-Boot 后的第一次启动数据丢弃，因为第一次启动会跑一遍音频初始化，给 `Linux to menu`
多加最多约 1 s（1.1.5 时记过同样的现象）。

## 测量方法

沿用上游方法（[docs/boot-time.md](../../docs/boot-time.md)）并做了适配：

- **`before Linux`** 由 `boot-clock` 读 `CNTVCT_EL0` 得到。ARM 通用计数器不被内核复位，
  所以这个数字是一次计数器读数：采样值减去 `CLOCK_MONOTONIC_RAW`，即“计数器起点 →
  内核时间基准原点”。本机原点落在 U-Boot 开头或略早于它（bootstage 的 `reset`
  记为 0、`board_init_f` 记为 7 ms），因此 bootrom、SPL 和 BL31 **都不在**本文任何数字
  之内。这也是比较两边必须用同一个时钟的原因。
- **U-Boot 内部分段**来自 bootstage（补丁 `0009`），它把每个阶段记进交给内核的设备树。
  在设备上这样读：

  ```sh
  for r in /proc/device-tree/bootstage/*/; do
      n=$(tr -d '\000' < "$r/name")
      t=$(od -An -tx1 "$r/mark" | tr -d ' \n')
      printf '%-18s %d ms\n' "$n" "$((0x$t/1000))"
  done
  ```

  `mark` 是同一个计数器、单位微秒，所以这些行与上面的原点同源。
- **内核时钟是核对过的，不是假设的。** 把 uptime 写进 `/dev/kmsg`，再读回 printk 时间戳：

  ```sh
  u=$(cut -d' ' -f1 /proc/uptime); echo "probe $u" > /dev/kmsg
  dmesg | grep probe | tail -1
  ```

  在 7.2.7 上两者相差约 20 ms（`[20.096]` 对 uptime `20.08`），说明 printk 与 uptime 共用
  内核原点——上游那个厂商内核不是这样，它的 printk 从开机算起。两个时钟不要混用。

## 结果

同一台设备、同一个 rootfs，只改了 U-Boot（0009 bootstage + 0010 dcache）。

| | 改前（1.2.2） | 改后（1.2.2 + 0009/0010） | 变化 |
|---|---|---|---|
| `before Linux` | 2.545–2.546 s | **1.890–1.891 s** | **−0.655 s** |
| `Linux to menu` | 2.16–2.60 s | 2.23–2.37 s | ≈ −0.1 s |
| `total` | 4.706–5.145 s | **4.120–4.261 s** | **−0.68 s**（均值） |

## 最终状态（1.2.3）

上面那次测量之后又有两处 U-Boot 改动落地：`0012` 跳过显示 ID 探测（面板本来就由
设备树路径选定），`0014` 去掉 200 ms 开机蜂鸣。两者都在 `board_late_init` 里，下一节
把这段拆成 235 ms。

| | 1.2.2 | +0009/0010 | +0012/0014（1.2.3） | +`blkcache`（1.2.3 源码） |
|---|---|---|---|---|
| `before Linux` | 2.545–2.546 s | 1.890–1.891 s | **1.654–1.655 s** | **1.475 s** |
| `Linux to menu` | 2.16–2.60 s | 2.23–2.37 s | 2.12–2.37 s | 2.23 s |
| `total` | 4.706–5.145 s | 4.120–4.261 s | **3.75–3.92 s** | **3.705 s** |

1.2.3 上三次均衡的暖启动读到 1.657 / 2.14 / 3.797 s。开机 logo 现在出现在 1.50 s
而不是 ~1.9 s，因为 rcS 在存储挂载完就立刻画，不再等那 400 ms 的按键采样窗口。

下面各节描述的是 1.890 s 那一版。它们的分段数字取自当时那次配置；此后没有东西挪动过
这些阶段，多出来的两个补丁只是从 `board_late_init` 尾部删掉了调用。

## 剩下的 1.890 s 花在哪

bootstage，三次启动之间稳定在 1 ms 以内：

| 阶段 | 计数器读数 | 分段 |
|---|---|---|
| `reset` | 0 ms | 计数器起点 |
| `board_init_f` | 7 ms | 进入 `board_init_f` |
| 首个 `board_r` initcall | 31 ms | 重定位前初始化 = **24 ms** |
| `initr_bootstage` | 53 ms | 标为 `board_init_r`，但这个标记打在 `initr_bootstage()` 内部，不在入口 |
| `main_loop` | 354 ms | 重定位后初始化 + 驱动模型 = **323 ms** |
| `bootm_start` | 1556 ms | **extlinux 扫描 + FAT + 读 21.6 MB = 1202 ms** |
| `start_kernel` | 1566 ms | bootm 准备 = 10 ms |

- 数据缓存确实在起作用：重定位前初始化只要 **24 ms**。上游在 MMU 关闭时测得 570 ms、
  开启时 40 ms；同一颗 SoC 上这里比他们更好。（本文档以前写的 45 ms，是把
  `board_init_r` 那条记录当成入口读出来的——并不是。）
- 内核入口 → 时间基准原点是 324 ms（`1890 − 1566`），它包含在 `before Linux` 里，
  但在 bootstage 之外。
- **装载段是最大的单块，而且不全是读卡。** 21.6 MB 按实测 24.6 MB/s 算是 0.84 s，
  所以约 0.35 s 是 GPT 遍历、`bootflow scan -lb`、`extlinux.conf` 解析和 FAT 元数据。
- 重定位后那 323 ms 里，有 235 ms 落在同一个调用上；下一节把它拆开。

## U-Boot 重定位后初始化的归因

bootstage 只标 `board_init_f`、`board_init_r`、`main_loop` 和 bootm 的几个阶段，而
`board_init_r` 的标记打在 `initr_bootstage()` 内部，所以整个重定位后初始化原本只有
一个数字。补丁 `0011` 加了 `CONFIG_BASEOS_INITCALL_TIMING`，在 `initcall_run_r()` 里
每个 `INITCALL()` 之前打一个标记；一次启动就能得到拆分。构建时还要加上
`CONFIG_BOOTSTAGE_RECORD_COUNT=120`——45 个标记放不进默认的 50 条里。

暖启动，架构计数器，单位 ms；差值就是每个标记之前那次调用花的时间：

| 调用 | ms | 说明 |
|---|---|---|
| `board_late_init` | **234.8** | 下面继续拆——其中 200.1 是一次 `mdelay` |
| `initr_dm` | 39.2 | 绑定并探测 37 个设备 |
| `initr_malloc` | 20.7 | |
| `power_init_board` | 16.1 | 通过 I2C 初始化 regulator |
| `initr_of_live` | 7.9 | |
| 重定位前序列（68 个调用） | 24.0 | 从 `board_init_f` 标记量到首个 `board_r` 调用 |
| 其余 | ~13 | `initr_env` 1.4、`initr_reloc` 0.9，剩下的 33 个都在 1 ms 以内 |

`board_late_init` 本身是一个调用，所以补丁 `0013` 在同一个开关下往
`rk_board_late_init()` 里加了标记。同样方式测得：

| 步骤 | ms | 说明 |
|---|---|---|
| `setup_boot_mode()` | 0.2 | ADC 下载键探测不是开销所在 |
| `set_gd_value()`、三次 `env_set()` | 0.0 | |
| `rgxx3_detect_display()` | **34.5** | DSI host 探测、DSI attach、DCS 读面板 ID |
| LED 写入 | 0.0 | |
| `startup_buzz()` | **200.1** | `pwm_set_enable`、`mdelay(200)`、`pwm_set_enable` |

对本文档在有标记之前的说法，有两处更正：

- 面板探测是 34.5 ms，不是 235 ms。它仍然是白花的——**没有任何东西消费它的结果**：
  它以 `env_set("panel", …)` 结束，而 `extlinux.conf` 和内核命令行都没有引用 `${panel}`
  （设备上出现 0 次）。它存在是因为 353 系列出过两种面板、当年启动脚本要用探测到的
  那一种去改 DT；本平台只出一份 DTB，面板由内核自己探测。
- `startup_buzz()` **确实执行了**，那 200 ms 就是它。即使该节点在预处理后的设备树里
  写着 `status = "disabled"`，它照样找得到 PWM（`pwm@fe6e0010`），所以先前“它会提前
  返回”的判断是错的。这个延时是故意的——蜂鸣要响这么久才听得见。

两者现在都能关：`CONFIG_RGXX3_SKIP_PANEL_ID`（0012）和
`CONFIG_RGXX3_SKIP_STARTUP_BUZZ`（0014），`uboot.config` 里都开着。

结果，三次暖启动：`before Linux` **1.891 → 1.654 / 1.655 / 1.655 s**，
`total` 4.09–4.26 → **3.75–3.92 s**。除非把 `CONFIG_RGXX3_SKIP_STARTUP_BUZZ` 从
`uboot.config` 里删掉，否则不会再有蜂鸣。

用户态这边，开机 logo 现在在 `rcS` 1.50 s 就上屏（绝对时间约 3.16 s），不再等那
400 ms 按键采样、拖到 ~1.9 s：`/run/boot-marks` 里 `storage mounted` 1.41 → `boot logo
drawn` 1.50。只有在第一次绘制失败时才会画第二遍。

注意诊断构建自身要花约 40 ms（1.890 → 1.930 s）：每个标记都是一次 DM timer 读取加
`show_boot_progress()`，而这样的标记有 45 个。

## 下一步值得做的

2026-11-03 对照 1.2.3 重新核对过。这份清单原来带的条目里，两条已经落地，其中一条当初
写的数字本身就是错的。

| 手段 | 状态 | 预期 | 代价 |
|---|---|---|---|
| 跳过面板 ID 探测（保留 VO 电源域和复位释放） | **已完成**（`0012`，1.2.3） | 实测 **34.5 ms**，不是本表以前写的 0.23 s | — |
| 跳过开机蜂鸣 | **已完成**（`0014`，1.2.3） | 实测 **200.1 ms**；本表以前根本没列这条 | — |
| 固定扇区 raw FIT，不扫描也不碰文件系统（`mmc read` + `bootm`） | **已否决**——1.2.3 实测，见下文 | 上限只有 **~0.29 s**，而试过的每种实现都比它省下的更贵 | 高：要动 build-image、更新路径，还要绕过读卡速率问题 |
| `blkcache` 处理 GPT 遍历 | **已完成**——1.2.3 实测，已进 `uboot.config` | 实测 **182 ms**，不是本表猜的 0.1 s | 低：一行配置，不动布局也不动更新路径 |
| 内核压缩 | **已否决**，不是没试过 | 净收益 0.06–0.26 s | 不值：要改镜像格式和 A/B 布局 |
| `initcall_blacklist` / 内核配置裁剪 | 未做，可选 | 只有 ~108 ms——下面实测，没有一个贵的 initcall | 低 |

在 `0012`/`0014` 和下面的 `blkcache` 之后，基线是 **1.475 s** `before Linux`、
**3.70–3.88 s** 总计。剩下的是约 1.0 s 的装载段和约 1.05 s 的内核初始化，两者都没有
可删的调用——这也正是当初该动装载段、而不是 `board_late_init` 的原因。

## raw FIT：实测后否决

2026-11-03 在 1.2.3 上用设备自带的 bootstage 标记做的。三个 U-Boot 版本被写进固定的
LBA 16384 区域，事后设备已恢复出厂 bootloader。

**1.2 s 的装载段到底花在哪。** 出厂 `bootflow scan -lb`：

| 标记 | ms |
|---|---|
| `main_loop`（U-Boot 完成） | 119 |
| `bootm_start` | 1323 |
| `boot_jump_linux` | 1334 |

所以扫描加载两者合计 1204 ms。而同样的 21.6 MB 用 `mmc read` 按裸扇区读只要
**898 ms**（24.1 MB/s）。因此 raw FIT 能删掉的只有 **~306 ms**，不是本文档以前假设的
0.35 s。

**两件没人记过的事：**

1. 这张卡在 U-Boot 里是 **`mmc 1`**，不是 `mmc 0`。`mmc dev 0` 会失败，后面的
   `mmc read` 跟着一起失败。
2. 只写 `mmc dev 1` 时卡只有 **5.4 MB/s**（21.6 MB 要 4000 ms）。速率必须显式点明——
   `mmc dev 1 0 2`（SD_HS）或 `0 9`（SDR104，这里结果一样，瓶颈在卡）才能得到 898 ms。

**raw FIT 实际要付多少。** 装同样内核和 DTB 的 FIT，读到 0x0A000000 后交给 `bootm`：

| 标记 | ms |
|---|---|
| `main_loop` | 119 |
| `bootm_start` / `boot_get_kernel` | 1245 |
| `fit_image_load`（重定位 + 校验 sha256） | 1246 → 1777 |
| `bootm_load_os` | 1795 |
| `boot_jump_linux` | 1927 |

`before Linux` 从 **1.658 变成 2.271 s**：FIT 不是更快，而是**慢了 613 ms**。读本身要
1126 ms，随后 `bootm` 又要花约 530 ms 把 21.6 MB 从 FIT 缓冲区搬到内核加载地址并做哈希，
远超扫描加 FAT 那 306 ms。

去掉哈希节点、让内核就地加载可以省回那 530 ms，最好情况约 286 ms，但没法干净地安排：
内核必须落在 2 MB 边界，而 libfdt 要求 FIT 自身 8 字节对齐，`mkimage` 把第一个 blob 放在
0xD4，两者都不满足。为了 286 ms 去破坏这条对齐规则、重写更新路径、再教 build-image
认识第二套布局，不值得。

压缩和 1800 MHz 解压这条在这里也是死路：读已经跑到 24.6 MB/s，缩小负载只买回约 0.56 s，
而解码要花 0.3–0.5 s。

## blkcache：实测后采纳

同一台设备、同一个 1.2.3、同样的 bootstage 标记。`blk_post_probe()` 会为每个 GPT 条目
槽位绑一个块设备，这 128 次查找每一次都重读分区条目数组——32 个 512 字节的块——而
U-Boot 的块缓存上限只保留 8 块，数组永远装不下、也永远不命中。`blkcache configure
32 32`（占用 32 MiB 堆里的 512 KiB）让第一次读取填满缓存，其余查找直接从内存返回。

| 标记 | 出厂 | `blkcache configure 32 32` |
|---|---|---|
| `main_loop` | 119 | 119 |
| `bootm_start` | 1323 | **1141** |
| `boot_jump_linux` | 1334 | 1151 |
| `before Linux` | 1.658 s | **1.475 s** |

182 ms，而且精确到毫秒可复现：四次暖启动加一次物理断电冷启动读到的都是 1141，说明决定
这个数字的是缓存容量，而不是卡上电时的状态。这条调用写在 bootcmd 里（`uboot.config`），
因为本机没有环境变量、也没有 distro 启动脚本可以放在扫描之前。build-image、更新路径和
分区布局一概不动——这正是它值得采纳、而 raw FIT 不值得的原因。

## 内核初始化归因

一次启动，把 `initcall_debug loglevel=7 log_buf_len=8M` 追加到
`/mnt/boot/extlinux/extlinux.conf` 的 `APPEND`（事后要恢复该文件；`initcall_debug` 输出是
KERN_DEBUG，`loglevel=3` 会把它藏起来）。828 个 initcall；内核约在 1.05 s 到达用户态。

内核阶段（用户态之前完成的 initcall），合计 **635 ms**：

| initcall | ms | 说明 |
|---|---|---|
| `rk3x_i2c_driver_init` | **134** | 上游测得 146 ms 并保留了：PMIC 和 muic 总线都在这里 |
| `cma_init_reserved_areas` | **92** | `CONFIG_CMA_SIZE_MBYTES=128` |
| `jent_mod_init` | **70** | jitterentropy 启动自检 |
| `of_platform_default_populate_init` | 48 | 结构性开销 |
| `clk_debug_init` | 38 | debugfs 时钟汇总，纯诊断用途 |
| `rk817_charger_driver_init` | 25 | |
| `param_sysfs_builtin_init` | 16 | |
| `chr_dev_init` / `slab_late_init` / `rockchip_drm_init` | 13 / 11 / 10 | |

rcS 阶段——模块加载，在 `rcS` 里**已经放到后台**（`( … ) &`），所以不在关键路径上，但仍
在抢 CPU 和 I/O。它们是 `Linux to menu` 那 ±0.1 s 波动的主要来源：

| initcall | ms |
|---|---|
| `deferred_probe_initcall` | **447** |
| `rtw_8821cs_driver_init` | **144** |
| `panfrost_driver_init` | 6 |

这排除了什么：并不存在一个 300 ms 的 initcall 等着被 blacklist。内核那 1.05 s 分摊在 828
个 initcall 上，外加 0.20 s 的 fbcon（`Console: switching to colour frame buffer device`）
和 0.17 s 的 SD 调优。内核侧唯一便宜的收益是约 108 ms：`CONFIG_CRYPTO_JITTERENTROPY`
（70 ms——但要确认 crng 初始化不回退）和 debugfs 时钟汇总（38 ms）。缩小 CMA 是拿 GPU/视频
余量换约 50 ms。

所以剩下的冗余在 U-Boot，不在内核：323 ms 的重定位后初始化（其中 235 ms 是一个调用），
以及装载段里约 0.36 s 的扫描/FAT 开销。
