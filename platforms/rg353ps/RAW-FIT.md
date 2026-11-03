# RG353PS raw FIT 启动实验报告

设备：Anbernic RG353PS，BaseOS 1.2.3（build `1fe0676-dirty-20261102145052`），
16 GB SD（SA16G）。测试日期 2026-11-03，全部数据取自 unit 自身的
`/proc/device-tree/bootstage` 记录（cntvct 微秒），而不是估算。

## 结论

**否决。** 理论收益上限只有 306 ms，而实测的两种 FIT 实现都比现状更慢，
其中最简单的一种慢 613 ms。不建议为它改动 build-image 与更新路径。

## 一、装载段到底花在哪里

原厂启动路径（`bootflow scan -lb`）：

| bootstage 标记 | ms |
|---|---|
| `reset` | 0 |
| `board_init_f` | 7 |
| `board_init_r` | 52 |
| `main_loop`（U-Boot 初始化完成） | 119 |
| `bootm_start` | 1323 |
| `boot_jump_linux` | 1334 |
| `start_kernel` | 1334 |

`before Linux` = 1.658 s，总计 3.858–3.878 s。

- 装载段 = `bootm_start − main_loop` = **1204 ms**
- 直接用 `mmc read` 把同样 21.6 MB 读进内存 = **898 ms（24.1 MB/s）**
- 因此扫描 + FAT + extlinux 这层的净开销 = **306 ms**

这 306 ms 就是 raw FIT 能删掉的全部，不是旧文档假设的 0.35 s。

## 二、两个此前没人记录的前提

1. **SD 卡在 U-Boot 里是 `mmc 1`。** `mmc dev 0` 直接失败，
   后面的 `mmc read` 跟着失败，而且失败是"瞬间返回"，在时间上看起来像
   "读取只花了 0 ms"，很容易误判成"读得很快"。
2. **`mmc dev 1` 不指定速度档，卡只有 5.4 MB/s**（21.6 MB 要 4000 ms）。
   必须写成 `mmc dev 1 0 2`（SD_HS）或 `0 9`（SDR104）。两种档位在这张卡上
   结果相同（898 / 897 ms），瓶颈在卡不在控制器。

单块读取对照：`mmc dev 1` + 读 1 个扇区 = 2 ms，证明设备初始化本身几乎不花钱，
898 ms 是纯传输。

## 三、FIT 实测：慢 613 ms

FIT（`mkimage`，kernel + dtb + sha256），写到 LBA 294912，`bootcmd` 为
`mmc dev 1 0 2; mmc read 0x0A000000 0x48000 <n>; bootm 0x0A000000`：

| bootstage 标记 | ms |
|---|---|
| `main_loop` | 119 |
| `bootm_start` / `boot_get_kernel` | 1245（读取 1126 ms） |
| `fit_image_load`（搬运 + 校验） | 1246 → 1777 |
| `bootm_load_os` | 1795 |
| `boot_jump_linux` | 1927 |

`before Linux` **1.658 → 2.271 s**，总计 3.878 → 4.511 s。

原因很清楚：`bootm` 把 21.6 MB 从 FIT 缓冲搬到内核加载地址并做 sha256 校验，
花了约 530 ms —— 比它省下的 306 ms 多得多。

## 四、能不能把 530 ms 省回来

可以，但代价不划算：去掉 hash 节点、并让内核"就地加载"（FIT 读到
`0x0A000000 − 0xD4`，使内核数据正好落在 `0xA000000`）。最好情况约
**286 ms**，可这要求：

- 内核数据落在 2 MB 边界（arm64 启动协议）；
- FIT 自身 8 字节对齐（libfdt 要求）；
- 而 `mkimage` 把第一个 blob 放在 `0xD4`（4 字节对齐），两个条件无法同时满足。

为 286 ms 去破坏对齐规则、改 build-image 的第二套布局、再改更新路径，不值得。

## 五、可复用的方法

- 这台机器没有串口控制台，U-Boot 的任何输出都看不到。用
  `if <cmd>; then sleep N; fi` 把每条命令的成败"编码"成时长
  （+1 s / +2 s / +4 s），再从 bootstage 总时长解码。这是无串口时唯一
  能看到 U-Boot 内部结果的可靠手段。
- 重刷 U-Boot 只需 `dd bs=512 seek=16384 conv=notrunc,fsync`，写后回读校验，
  全程可通过 SSH 完成，不必拔卡。
- 每次改动前先在本地重建一次原厂 U-Boot 并比对 sha256：本次得到
  `dc7d3f65…`，与设备上运行的那份逐字节一致，因此后续差异都能确定来自改动本身。

## 六、现场状态

- 实验写入备用 BOOT 半区（LBA 294912）的 21 MB FIT 已清零。
- U-Boot 最终版本是采纳 `blkcache` 的构建（`83124110…`），不再是出厂版；
  出厂版（`dc7d3f65…`）保留为回退备份 `uboot-backup/u-boot-live.img.gz`
  （出厂 U-Boot 区域 8 MiB）。

## 七、实验之后：装载段换了个方向，省下 182 ms

raw FIT 被否决，但同一个 bootstage 数据指出另一处浪费：U-Boot 的 GPT 遍历。
`blk_post_probe()` 为 128 个 GPT 条目各绑一次块设备，每次重读同一个 32 块
（16 KiB）的条目数组，而块缓存默认上限是 8 块，一次都命不中。

在 `bootcmd` 前加一句 `blkcache configure 32 32`（占 512 KiB 堆）后，
`bootm_start` 1323 → 1141 ms，`before Linux` 1.658 → **1.475 s**。
四次暖启动加一次物理断电冷启动读数逐毫秒一致。该改动已进
`platforms/rg353ps/uboot.config`，细节见 [BOOT-TIME.md](BOOT-TIME.md)。

## 八、建议的下一步

装载段已无可挖空间（raw FIT 上限 306 ms 且实现成本高于收益，GPT 遍历那 182 ms
已经拿到），把注意力放回内核侧：`before Linux` 1.475 s 中有约 324 ms 在任何
bootstage 记录之前（bootrom/SPL/BL31），剩余可动的只有 `initcall_blacklist`
那 ~108 ms；若还要更大幅度，只能从"少读 21.6 MB"入手（内核瘦身或压缩），
而压缩已被否决过。
