# 固定扇区 raw FIT 装载：可行性分析

RG353PS / 1.2.3 基线。分析对象：把内核装载从 `bootflow scan -lb` + FAT + extlinux 改成固定扇区 `mmc read` + `bootm`。

> 本文是动手之前的分析，保留原始判断以便对照。实测结果见
> [RAW-FIT.md](RAW-FIT.md)：**否决**，两种 FIT 实现都比现状慢，最省的一种慢 613 ms；
> 装载段最终的 182 ms 是从 U-Boot 的 GPT 遍历（`blkcache`）拿到的，不是 FIT。

---

## 0. 结论

**可行，但收益比移交文档写的更保守，实现成本比它写的更高。**

| 项 | 判断 |
|---|---|
| 理论收益 | **~0.30 s**（装载段 1.202 s 中的扫描/FAT/extlinux 部分），总启动 3.80 → ~3.50 s，约 8% |
| 不省的 | 读 21.6 MB 的 **0.84 s 一分不少**（FIT 不压缩，压缩已被 BOOT-TIME 否决） |
| 硬件风险 | 低。不改分区表、不改 SPL 路径，最坏是 U-Boot 起不来，回刷 UBOOT 分区即可 |
| 工程成本 | **中等偏高**。现成工具没有一个能直接用（见 §2.3），正式方案还要动 gptslot |
| 建议 | 先做 §4 的零布局改动实验测真实收益，再决定是否动正式布局 |

一个必须先纠正的前提：**`tools/mkfit.py` 不能直接用于 RG353PS**。它是 my355（Miyoo Flip）专用的——输入是 vendor Android boot image、内核 zstd 压缩、输出带 `MY355FIT` 512 B header、写 `MY355_*` DRAM 地址。RG353PS 走 extlinux + 裸 `Image` + 独立 DTB，不用 Android boot image，也不压缩内核。能复用的只有里面的 FDT 构造/解析（`Node`/`build_fdt`/`parse_fdt`，约 150 行），FIT 组装逻辑要重写。

---

## 1. 第 1 步：BOOT-TIME.md 旧清单与 1.2.3 状态统一

已在 `platforms/rg353ps/BOOT-TIME.md` 的 “What is worth doing next” 一节就地改写。差异如下：

| 旧清单条目 | 旧值 | 1.2.3 实际 | 处理 |
|---|---|---|---|
| Skip panel-ID detection | ~0.23 s，待做 | **已完成**（`0012`），实测 **34.5 ms** | 旧值是错的，差 6.7 倍；改标注 done + 真值 |
| （旧清单没有这一条） | — | **startup buzz 200.1 ms，已完成**（`0014`） | 补进清单，标 done |
| Raw FIT 固定扇区 | ~0.3 s，待做 | 待做，估算成立 | 保留，标为本轮目标 |
| `blkcache` GPT | ~0.1 s | 待做 | 保留 |
| 内核压缩 | 0.06–0.26 s，不值 | 结论成立 | 改标 **rejected**（已否决，非未尝试） |
| initcall 黑名单 / 内核裁剪 | ~108 ms | 结论成立 | 保留，标可选 |

统一后的基线一句话：`before Linux` **1.654 s**、总 **3.75–3.92 s**；`board_late_init` 里已经没有可删的调用，剩下的是 **1.2 s 装载段** 和 **1.05 s 内核 init**。

---

## 2. 第 2 步：现状启动链与 raw FIT 槽位寻址设计

### 2.1 现状（1.2.3，代码实证）

- U-Boot `CONFIG_BOOTCOMMAND` 走 Standard Boot 默认值 `bootflow scan -lb`（`platforms/rg353ps/build-uboot.sh` 没有覆盖它，`uboot.config` 也没有）。
- `BASEOS_BOOT` 是 **FAT32**，内容：`Image`（21.6 MB，未压缩）、`device_trees/rk3566-anbernic-rg353ps.dtb`、`extlinux/extlinux.conf`、`baseos.conf`、`bootlogo.bmp`。
- 装载 = 遍历分区找 `extlinux.conf` → 解析 → FAT 读 `Image` + DTB → `bootm`。
- BOOT-TIME 实测：`bootm_start` 1556 ms − `main_loop` 354 ms = **1202 ms**；其中读 21.6 MB 占 **840 ms**（24.6 MB/s），**其余 ~360 ms 是 GPT 遍历 + scan + extlinux 解析 + FAT 元数据**。

关键结构事实（决定方案可行性）：

1. **gptslot 的备用半区本来就是未分配 raw 空间**。`src/gptslot.c` 注释原文：“only ever makes one half a partition; the other is unallocated space reached by raw offset”。所以 raw FIT 不需要新造一块地。
2. **update 路径与分区内容格式无关**。`tools/mkupdate.py` 按 LBA 整块 `gzip`（`pack()` 从 `start * SECTOR` 读 `sectors * SECTOR`），`baseos-update` 再整块 `dd` 到 inactive 半区后 `gptslot flip`。**换成 raw FIT 不用改更新机制**——这是最大的正面结论。
3. **A/B 的“当前槽”只由 GPT 分区位置表达**。没有任何东西记录“现在是 A”。所以 raw FIT 必须跟着分区走，否则 U-Boot 无法知道该读哪半。

### 2.2 四种寻址方案

| 方案 | 布局改动 | 跳过 scan | 跳过 FAT | 跳过 extlinux | 预计收益 | 主要代价 |
|---|---|---|---|---|---|---|
| **A. `BASEOS_BOOT` 整体改 raw FIT** | 大 | ✓ | ✓ | ✓ | ~0.35 s | `bootlogo.bmp` 无处安放（前端写 logo 的 patch 要改）；失去 FAT 维护面 |
| **B. 每半区 = raw FIT + FAT** | 中 | ✓ | ✓ | ✓ | ~0.35 s | 分区大小 ≠ 半区大小，**必须改 gptslot 几何模型**；update region 语义变复杂 |
| **C. 实验：FIT 写 inactive 半区** | **0** | ✓ | ✓ | ✓ | ~0.35 s（可测真值） | 不能用于正式（下次更新会覆盖），只做实验 |
| **E. `load mmc 0:2 /fit.itb`** | 0 | ✓ | ✗（仍解析 FAT） | ✓ | ~0.15–0.2 s | 收益小，仍受 FAT 影响 |

**推荐路径：先用 C 测真值，正式合并再谈 B。** 理由：C 不动分区表、不动 gptslot、不动 update，只用一次 U-Boot 重编就能回答“这 0.3 s 值不值”；如果实测只省 0.1 s，B 的工程成本就不划算。

方案 A 被排除的直接原因：`bootlogo.bmp` 现在在 FAT 启动分区，`rcS` 从 `/mnt/boot/bootlogo.bmp` 读、前端 `slot-bootlogo.patch` 往启动分区写。改成 raw FIT 后这两条都要重做，属于本目标之外的连锁改动。

### 2.3 LBA 计算（全部来自 build-image.sh 常量）

```
UBOOT_START    = 16384      UBOOT_SECTORS = 16384   (8 MiB)
BOOT_START     = 32768      BOOT_SECTORS  = 262144  (128 MiB/半)
ROOT_START     = 557056     ROOT_SECTORS  = 1048576 (512 MiB/半)
DATA_START     = 2654208
```

| 区域 | active A | 备用 B |
|---|---|---|
| BOOT | 32768 – 294911 | **294912 – 557055** |
| ROOT | 557056 – 1605631 | 1605632 – 2654207 |

FIT 实测尺寸预算：`Image` 21.6 MB + DTB ~100 KB + FDT 头 ~2 KB ≈ **21.7 MB**。实验取固定读长 **24 MiB = 49152 扇区**（多读 2.3 MB ≈ 0.09 s，换来 bootcmd 不需要解析长度）。

### 2.4 实验 bootcmd（方案 C）

U-Boot 无串口，命令必须编进 `CONFIG_BOOTCOMMAND`。在 `platforms/rg353ps/uboot.config` 追加：

```
CONFIG_BOOTCOMMAND="mmc dev 0; mmc read ${kernel_addr_r} 294912 49152; bootm ${kernel_addr_r}"
```

- `294912` = 当前卡 active 为 A 时的 BOOT 备用半区起点。**必须先 `gptslot geometry` 确认 `SLOT_BOOT_INACTIVE`**，active 是 B 时这个值要换成 32768。
- `${kernel_addr_r}` 由 U-Boot 环境提供（RK3566 系列通常 `0x02080000`），首轮实测确认它 ≥ 24 MiB 可用且不与 FIT 内 load 地址冲突。
- `bootm` 会按 FIT 里的 `load` 属性重定位，所以读地址与运行地址可以不同。

### 2.5 FIT 结构（RG353PS 版）

复用 `mkfit.py` 的 `Node`/`build_fdt`，但去掉 my355 的 Android boot image、zstd、`MY355FIT` header：

```
/ (root)
  description = "BaseOS RG353PS"
  #address-cells = 1
  images/
    kernel/  type=kernel  os=linux  arch=arm64  compression=none
             load=0x02080000  entry=0x02080000  data=<Image>
    fdt/     type=flat_dt arch=arm64  compression=none  data=<dtb>
  configurations/
    default = "conf"
    conf/    kernel="kernel"  fdt="fdt"
```

bootargs 直接写进 DTB 的 `/chosen/bootargs`（复用 `rkbootimg.set_bootargs`），与现在 `extlinux.conf` 的 `APPEND` 逐字一致：

```
root=PARTUUID=d462d29a-c5ca-4a4f-90c1-8d9423dd3535 rootfstype=ext4 rootwait ro
console=ttyS2,1500000n8 quiet loglevel=3 vt.global_cursor_default=0 init=/sbin/init
```

不加 hash 节点——`bootm` 视为可选，而 sha256 整核正是这条路径要删掉的工作。

### 2.6 需要改的文件（方案 B 正式合并时）

| 文件 | 改动 |
|---|---|
| `tools/mkfit-rg353ps.py`（新） | 从 `Image` + `.dtb` 生成上面结构的 FIT |
| `platforms/rg353ps/uboot.config` | 覆盖 `CONFIG_BOOTCOMMAND` |
| `platforms/rg353ps/build-image.sh` | 每半区前 32 MiB 写 FIT，FAT 后移 32 MiB；`DATA_START` 不变 |
| `src/gptslot.c` | `derive()` 的半区模型：分区大小 ≠ 半区大小 |
| `platforms/rg353ps/build-update.sh` | boot region 的 LBA/大小来源改为“FIT 区”，或继续整块（推荐继续整块，mkupdate 不用改） |
| `src/fbsplash.c` + `rcS` + `slot-bootlogo.patch` | logo 位置迁移（方案 B 可保留一个小 FAT，改动可控） |

---

## 3. 收益的构成（为什么是 0.3 s 不是 0.84 s）

| 段 | 现状 | raw FIT 后 | 变化 |
|---|---|---|---|
| GPT 遍历 | ~? ms | 0（固定 LBA） | − |
| `bootflow scan -lb` 分区遍历 | 占 360 ms 的主体之一 | 0 | − |
| `extlinux.conf` 解析 | 小 | 0 | − |
| FAT 目录/簇链/元数据 | 占 360 ms 的主体之一 | 0 | − |
| 读 21.6 MB | 840 ms | ~840 ms（24 MiB 读约 930 ms） | **+90 ms（多读 padding）** |
| `bootm` 解析 FIT | 0 | ~10 ms | +10 ms |

净收益 ≈ 360 − 90 − 10 ≈ **260 ms**，落在文档估的 0.3 s 附近，但**下限可能到 0.15 s**，取决于 scan/FAT 各占多少（当前没有拆分数据，这正是实验要测的）。

---

## 4. 第 3 步：实验设计（需真机，我无法代跑）

> 我这边只有源码和文档，没有 RG353PS 实机与 SD 卡，第 3、4 步的“上机测量”必须由你执行。下面是可直接照做的步骤。

### 4.1 前置

1. 用 1.2.3 正式镜像做基线，**先测 3 次暖启动**，记录 `before Linux` 与 bootstage 的 `bootm_start` / `start_kernel`，确认装载段 ≈ 1202 ms。
2. 备份当前 `u-boot.bin`（`work/rg353ps/rg353ps-uboot.bin`）和整卡前 32 MiB。
3. 卡上**禁用自动更新**（实验期间 update 会覆盖 inactive 半区——那正是 FIT 的落脚点）。

### 4.2 生成 FIT 并写入 inactive 半区

```sh
# 1) 确认哪一半是备用
gptslot /dev/mmcblk1 geometry      # 取 SLOT_BOOT_INACTIVE

# 2) 生成 FIT（新工具，先用 24 MiB 固定长度）
python3 tools/mkfit-rg353ps.py \
  --image work/rg353ps/kernel/output/Image \
  --dtb   work/rg353ps/kernel/output/rk3566-anbernic-rg353ps.dtb \
  --root  PARTUUID=d462d29a-c5ca-4a4f-90c1-8d9423dd3535 \
  --out   work/rg353ps/boot.fit

# 3) 写到备用半区起点（按 geometry 的实际值替换 294912）
dd if=work/rg353ps/boot.fit of=/dev/mmcblk1 bs=1M oflag=seek_bytes \
   seek=$((294912 * 512)) conv=notrunc status=none
sync
```

### 4.3 重编 U-Boot 并只刷 UBOOT 分区

```sh
# uboot.config 里加 §2.4 的 CONFIG_BOOTCOMMAND（LBA 用 geometry 的真值）
./platforms/rg353ps/build-uboot.sh

# rg353ps-uboot.bin 是组合体：SPL 在 LBA 64、u-boot.itb 在 LBA 16320，
# 与 build-image.sh 的写入方式一致——整块从 LBA 64 回写（不在 A/B 内）
dd if=work/rg353ps/rg353ps-uboot.bin of=/dev/mmcblk1 bs=1M \
   oflag=seek_bytes seek=$((64 * 512)) conv=notrunc status=none
sync
```

### 4.4 测量

上机后读 bootstage，只看两段：

```sh
for r in /proc/device-tree/bootstage/*/; do
  n=$(tr -d '\000' < "$r/name")
  t=$(od -An -tx1 "$r/mark" | tr -d ' \n')
  printf '%-18s %d ms\n' "$n" "$((0x$t/1000))"
done
```

判定：`start_kernel − bootm_start` 从 **1202 ms** 降到多少，就是这条路径的真实收益。同时 `before Linux`（`boot-clock`）应同步下降。

### 4.5 快速回滚

保留旧 `u-boot.bin`，同样 `dd` 回 LBA 64（`seek=$((64*512))`）即可。分区表没动过，回滚不改任何数据区。

---

## 5. 第 4 步：稳定性验证（通过才谈合并）

| 项 | 标准 |
|---|---|
| 暖启动 | ≥ 10 次 `reboot`，每次进系统 |
| 冷启动 | ≥ 10 次断电/拔卡重插，每次进系统 |
| 时间一致性 | 装载段方差 < ±50 ms；`before Linux` 不高于基线 |
| 失败模式 | 记录 bootm 报错（若有）；U-Boot 无串口，失败靠 bootstage 缺失 + 红灯判断 |
| 交叉验证 | 至少一次把看门狗/电源键路径也走一遍，确认 FIT 路径不影响关机与休眠 |
| 回滚演练 | 主动刷回旧 U-Boot，确认能回到基线 |

只有以上全过，才讨论方案 B 的布局改造；否则停在“已测量、不合并”。

---

## 6. 风险清单

1. **`kernel_addr_r` 不确定**。U-Boot 环境里的实际值要首轮实测；若 < 24 MiB 可用空间，读会踩到别的东西，表现为静默 hang（无串口）。
2. **inactive 半区会被 update 覆盖**。实验期必须禁更新，否则 FIT 被冲掉，下次开机直接不启动。
3. **FIT load 地址与 DTB 里 `/memory` 预留冲突**（OP-TEE / CMA）。RG353PS 不需要 my355 的 OP-TEE 预留，但 CMA 128 MB 仍在，读地址要避开。
4. **多读 24 MiB 固定长度**在 kernel 变小时反而更慢；正式版应改回“header 存 sectors”两段读。
5. **没有串口**：任何 U-Boot 层错误都只能靠 bootstage 与 LED 推断，调试成本高——这也是建议先做 C 而不是直接上 B 的原因。

---

## 7. 建议的下一步

1. 先实现 `tools/mkfit-rg353ps.py`（约 150 行，复用 `mkfit.py` 的 FDT 代码），离线生成 FIT 并用 `mkfit.py info` 自检。
2. 按 §4 在**一张备用卡**上跑方案 C，拿到真实装载段数字。
3. 数字 ≥ 0.25 s 再启动方案 B 的布局设计；< 0.15 s 就放弃，转向 `blkcache`（~0.1 s、成本低）和内核侧 108 ms。
