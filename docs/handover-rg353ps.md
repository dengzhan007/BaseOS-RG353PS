# RG353PS 移交说明（1.2.3）

写于 2026-11-03。上一版是 1.0.1（2026-10-30），已经停在 A/B 布局刚跑通的那天，这一版把它之后的所有事情补上：启动时间的三轮优化、bootlogo 的两个毛病、构建提速、仓库搬到 GitHub 并接上 CI。

读的顺序：本文 → `platforms/rg353ps/BOOT-TIME.md`（启动时间账本，唯一权威数据）→ `platforms/rg353ps/README.md`（移植与构建细节）。

---

## 1. 一句话现状

1.2.3 已经在真机上跑着，冷启动 3.75–3.92 s（从 U-Boot 计时原点到菜单出现），全链路在 GitHub Actions 上一次跑通并产出完整包与升级包。源码只有一个分支 `main`，HEAD 是 `6000c69`。

| 项 | 状态 |
|---|---|
| 版本 | `1.2.3`（仓库根 `VERSION`） |
| 真机 | 已升级到 1.2.3，干净启动 1.657 / 2.14 / 3.797 s |
| 构建 | 本地与 GitHub Actions 都能端到端产出；CI 单次 14 分钟 |
| 分支 | 只有 `main`，默认分支即 `main` |
| 本地仓库 | `F:\workspace\2026-10-28-22-11-37\srcwork\baseos-my355` |
| 远端 | `https://github.com/dengzhan007/BaseOS-RG353PS` |

## 2. 交付物在哪

### 2.1 GitHub Actions（推荐从这里取）

最近一次成功构建：[run 41474768332](https://github.com/dengzhan007/BaseOS-RG353PS/actions/runs/41474768332)，artifact 名 `baseos-rg353ps-1.2.3`，共 238 MiB，四个文件：

| 文件 | 用途 |
|---|---|
| `baseos-rg353ps-1.2.3.img.gz` | 完整镜像，解压 2.0 GiB。新卡整卡刷 |
| `baseos-rg353ps-1.2.3.bosupd` | 升级包，放卡根目录开机自动应用，不刷整卡 |
| `baseos-rg353ps-1.2.3.sha256` | 上面两个的校验值 |
| `baseos-rg353ps-1.2.3.build.txt` | 版本、commit、内核 release、构建时间 |

Artifact 需要登录 GitHub 才能下载，网页端在 run 页面底部 Artifacts 区域。

### 2.2 本地构建产物

| 文件 | 大小 |
|---|---|
| `work/rg353ps/baseos-rg353ps-smoke.img.gz` | 134 MB |
| `work/rg353ps/baseos-rg353ps-1.2.3.bosupd` | 116 MB |

刷写与升级的手法见 `platforms/rg353ps/README.md`；要点是：整卡刷用 `dd` 或 balenaEtcher 写 `.img.gz`，日常升级只把 `.bosupd` 拷到卡根目录再开机。

## 3. 这一轮做了什么（1.0.1 → 1.2.3）

### 3.1 启动时间：2.545 s → 1.654 s（到内核）

三轮，全部在真机上用 bootstage 与 boot marks 量的，明细在 `BOOT-TIME.md`。

| 轮次 | 改了什么 | before Linux | total |
|---|---|---|---|
| 基线 1.2.2 | — | 2.545–2.546 s | 4.71–5.15 s |
| 第一轮 | U-Boot 开 bootstage（0009）、relocation 前开 dcache（0010） | **1.890 s** | 4.12–4.26 s |
| 第二轮 | 跳过面板 ID 探测（0012）、去掉开机蜂鸣延时（0014） | **1.654 s** | 3.75–3.92 s |
| 附带 | rcS 里 logo 提前到存储挂载后 | — | logo 1.9 s → 1.50 s |

第一轮里最值钱的是 dcache：pre-relocation init 从上游实测的 570 ms（MMU off）降到 **24 ms**，比上游同 SoC 的 40 ms 还好。它不需要改硬件，是一条 patch。

第二轮的两个改动都在 `board_late_init` 里，那 234.8 ms 的拆分是：`setup_boot_mode` 0.2 / `set_gd_value`+`env_set` 0.0 / `rgxx3_detect_display` **34.5** / `startup_buzz` **200.1**。

- `0012` 跳过面板探测：`${panel}` 全链路无人引用，面板本来就按 DTB 路径选；VO 电源域保留不动。另一种面板（353 有两种屏）不受影响，因为不再按 ID 探测，两者都走 DTB。
- `0014` 跳过蜂鸣器延时：这是产品决策，不是性能妥协。想要开机"滴"一声，把 `platforms/rg353ps/uboot.config` 里的 `CONFIG_RGXX3_SKIP_STARTUP_BUZZ=y` 删掉重编 U-Boot 即可。

### 3.2 bootlogo：从"从上到下刷出来"到整帧显示

现象是屏幕点亮后能看到画面一行行往下长。原因是 `src/fbsplash.c` 逐像素往 framebuffer 写，而那块 framebuffer 是 uncached 的，每次写都直接打到显存，写多快就长多快。

改法：整张 BMP 一次 `fread` 进内存，在可缓存的 RAM 里合帧，最后单次 `memcpy(fb, frame, stride*H)`。像素与原逐像素版做过 `PIXELS_IDENTICAL` 比对，冷读 0.14 s → 0.04 s。

同一个改动还带来一个额外结果：`FBSPLASH_TEST` 可以离线渲染，没有真机也能验证画面对不对。

### 3.3 bootlogo 提前到屏幕点亮

原来 rcS 在背光打开后还要等 400 ms 的按键采样窗口才画 logo。现在改成存储挂载完成就画（1.50 s），按键采样照旧进行；后面保留一个 `[ "$BOOT_LOGO_DRAWN" -eq 0 ]` 的兜底，万一前面失败还会补画。

这一条不影响总启动时间（菜单出现时刻不变），只影响"屏幕亮到看见东西"的体感。

### 3.4 构建提速：10m36s → 2m01s（本地镜像步骤）

两件事：

1. **`dd bs=512` 是元凶**。写 512 MiB 的 rootfs 分区要 100 万次 `write()`，在 WSL 的 9p 挂载上落到 Windows 盘，实测 340 s；改 `bs=1M oflag=seek_bytes` 之后 5 s。整条镜像步骤 10m36s → 2m01s，dd 段 476 s → 10 s。
2. **清华源一直"假生效"**。`debian:bookworm-slim` 没有 CA 证书，https 镜像必然证书校验失败，之前靠包索引残留蒙过去，某次直接 `E: Unable to locate package gdisk`。现在 `DEBIAN_MIRROR` 环境下若无 CA 自动降级为 http（apt 仍验签名），`ALPINE_MIRROR` 同理。

`build-image.sh` 里还加了 `ts()` 阶段时间戳，以后哪一步慢可以直接看日志。

（如果只看"构建慢"这个现象，很容易误判成镜像源没生效。日志里其实一直有 mirror 行，apt 只花 15–19 s。）

### 3.5 仓库与 CI

- 仓库换成 `BaseOS-RG353PS`，只保留 `main` 一个分支，About 描述已清空，等统一重写。
- 新增 `.github/workflows/rg353ps-release.yml`：手动触发，跑完整链路后执行 `build-update.sh`，一次产出完整包 + 升级包 + 校验 + 构建信息。填 `release_tag` 输入还会挂到对应 Release 上。
- 原来的 bring-up CI 仍保留，push 到 `main` 时跑（不再产 release）。

## 4. 现在的 1.654 s 花在哪

| 区段 | 耗时 | 说明 |
|---|---|---|
| U-Boot 到 relocation | 24 ms | dcache 生效后的 pre-relocation init |
| post-relocation init | 323 ms → **88 ms** | 砍掉 0012/0014 后的剩余 |
| 装载段（`bootm_start`） | **~1.2 s** | 读 21.6 MB 占 0.84 s（24.6 MB/s），其余 ~0.35 s 是 GPT 遍历、`bootflow scan -lb`、extlinux 解析、FAT 元数据 |
| bootm 收尾 | 10 ms | — |
| 内核 init（到用户态） | ~1.05 s | 828 个 initcall，见下 |

内核侧没有"300 ms 级元凶"可砍，实测合计 635 ms，最大的三个是 `rk3x_i2c` 134 ms（PMIC/muic 总线，上游同样保留）、`cma` 92 ms、`jent` 70 ms。省钱的只有 ~108 ms（关 jitterentropy 70 ms + 关 debugfs 时钟汇总 38 ms），代价要评估。

**下一步最大的一块是装载段**，方向是让 FIT 从固定扇区 raw 读、跳过 bootflow scan 与 FAT，理论收益 ~0.3 s。这是唯一还在桌面上的大块。

## 5. 在新机器上恢复与构建

### 5.1 环境

Linux 或 WSL2（Ubuntu 24.04 实测）、Docker 守护进程、Python 3、Git。x86_64 需要 arm64 模拟：

```sh
docker run --privileged --rm tonistiigi/binfmt --install arm64
```

国内建议先设镜像（都能用环境变量开）：

```sh
export ALPINE_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.22
export DEBIAN_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/debian
```

### 5.2 从仓库构建

```sh
./platforms/rg353ps/build-uboot.sh     # idbloader + u-boot.itb → work/rg353ps/rg353ps-uboot.bin
./platforms/rg353ps/build-firmware.sh  # RTL8821CS 固件 + regulatory.db
./platforms/rg353ps/build-kernel.sh    # 内核 + DTB + 模块 → work/rg353ps/kernel/output
./platforms/rg353ps/build-rootfs.sh    # BusyBox 根文件系统（arm64 容器）
./platforms/rg353ps/build-image.sh     # 组装 2 GiB 镜像
./platforms/rg353ps/build-update.sh    # 生成 .bosupd
```

增量重建：只改 rootfs 脚本就重跑 `build-rootfs.sh` → `build-image.sh` → `build-update.sh`；只改 `src/*.c` 同样，`build-rootfs.sh` 会重新交叉编译。

### 5.3 在 CI 上构建

Actions 页面选 `RG353PS release build` → Run workflow（分支 `main`）→ 跑完在 Artifacts 取四个文件。要挂 Release 就在 `release_tag` 里填 `v1.2.3` 之类的 tag。单次约 14 分钟。

## 6. 代码地图

```
platforms/rg353ps/
  build-*.sh          六个构建步骤，相互独立，只读写 work/rg353ps/
  uboot.config        U-Boot defconfig 片段（BOOTDELAY=0、bootstage、两个 rgxx3 开关）
  kernel/             内核 config、ROCKNIX 补丁源与出处、regdb 证书
  patches/            U-Boot 补丁 0001–0014（见 7.2）
  rootfs/usr/sbin/    目标机全部工具脚本
  frontends/slot/     Slot 前端移植资产（包内单独一份，见第 9 节）
src/
  gptslot.c           读/翻 A/B 槽位，唯一的 GPT 写入者
  gptgrow.c           首次开机把 BASEOS_DATA 扩到卡尾
  gpt.h               分区几何常量，改布局从这里起
  fbsplash.c          启动 logo 绘制（1.2.2 改成整帧 memcpy）
  pwrkeyd.c           电源键守护：短按休眠、长按关机
  fatdirty.c / rebootmode.c
tools/                mkfit / mkupdate / mkbootlogo 等
```

U-Boot 补丁里，与启动时间相关的是 0008–0014：

| 补丁 | 作用 |
|---|---|
| 0008 | rk3568 dw_mmc 内部分频 /2 导致只能跑 25 MHz，修好后 24.6 MB/s |
| 0009 | bootstage 报告前把 FDT 撑开（否则记录被截断） |
| 0010 | relocation 前开 dcache，pre-reloc init 570 → 24 ms |
| 0011 | 给 initcall 打点的诊断补丁，默认关闭（`CONFIG_BASEOS_INITCALL_TIMING=n`） |
| 0012 | 跳过面板 ID 探测，省 34.5 ms |
| 0013 | `rk_board_late_init` 内部 7 处打点，诊断用 |
| 0014 | 跳过开机蜂鸣延时，省 200 ms |

## 7. 磁盘布局（自 1.0.1 未变）

| 分区 | 起止 LBA | 大小 | A/B |
|---|---|---|---|
| `BASEOS_UBOOT` | 16384 | 8 MiB | 否，SPL 按固定扇区读 |
| `BASEOS_BOOT` | 32768 / 备用 294912 | 128 MiB | 是 |
| `BASEOS_ROOT` | 557056 / 备用 1605632 | 512 MiB | 是 |
| `BASEOS_DATA` | 2654208 → 卡尾 | 首次开机扩展 | 否，用户数据 |

备用半区**故意不建分区**：不占分区号，桌面系统不会提示格式化，翻转时分区号不位移。所有区域从 LBA 16384 起前向平铺，`BASEOS_DATA` 正好落在最后一个备用半区之后——不变量写在 `src/gptslot.c` 注释里，改布局必须一起改。

## 8. 踩过的坑

### 8.1 U-Boot

- **不要改全局 `INITCALL()` 宏**。为了归因 post-relocation 的 302 ms，曾把 `include/initcall.h` 的宏改成逐调用打点，结果 `common/board_f.c` 里 68 处 pre-relocation 调用在 timebase 还没就绪时就开始打点，设备红灯不启动。恢复办法是读卡器对 `\\.\PhysicalDriveN` 偏移 32768 回写旧的 `u-boot.bin`。补丁最终只作用于 `board_r.c`。
- **bootstage 记录会被截断**。FDT 空间不够时记录静默丢失，必须先在报告前撑开 FDT（0009）。
- 判断"某段耗时"不要靠猜：`startup_buzz` 那次先以为是面板探测（实际 34.5 ms），又以为蜂鸣器没运行（其实 200 ms 就是那个 `mdelay`）。打点拆开就一目了然（0013）。

### 8.2 构建

- `sh -euc '...'` 里不能出现英文撇号，注释里写 `platform's` 会把引号撕裂。
- 绝对符号链接的 `[ -e ]` 判定会失败，rootfs 里 `/bin` 链到 `/usr` 必须用 `[ -e ] || [ -L ]`。
- `baseos-release` 的校验语句必须排在生成它的 heredoc 之后。

### 8.3 Git / 跨平台（这次新增，最容易复发）

- **Windows 上 `core.filemode=off`，脚本会以 `100644` 进索引**。本地文件系统看着有执行位，Linux runner checkout 出来就没有，`build-rootfs.sh` 的 `test -x` 直接失败（`boot timing tool is missing: usr/sbin/baseos-boot-mark`）。新增 rootfs 脚本后用 `git ls-files -s <file>` 确认是 `100755`，不是就 `git update-index --chmod=+x`。**不要在构建脚本里加 chmod 兜底**，那会把这个错误永久藏起来。
- **换行**：`.gitattributes` 已经给 rootfs 脚本、patch 集、`VERSION` 钉了 `eol=lf`，新增这类文件记得加规则。
- 不要在 Windows 侧解压源码包，执行位和换行都会坏。

### 8.4 网络

- 本机代理对 `github.com:443` 返回 CONNECT 502，`git push` 不通；`api.github.com`、`codeload`、`ssh.github.com:443` 是通的。必要时用 Git Data API 推（见 10.2）。
- RNDIS 上网时 Windows 会多出第三条默认路由（metric 25）抢出口，部分网址异常。把该网卡 IPv4 跃点改成 9000：`Set-NetIPInterface -InterfaceAlias "..." -AddressFamily IPv4 -InterfaceMetric 9000`。

## 9. 包内还有一份 Slot 移植文档

`slot-移植/` 目录是给"换一个 Slot 系前端 fork 怎么接上"用的，内容与该目录一一对应：

| 文件 | 作用 |
|---|---|
| `PORTING.md` | 主文档：心智模型、最小改动集 A–G、10 分钟流程、上机验证清单、摇杆分层排查 |
| `fbdev.rs` | 整体替换 `crates/slot-gfx/src/fbdev.rs` 的实现 |
| `launch.sh` | BaseOS 前端约定的启动脚本 |
| `slot-analog.patch` | 摇杆变真模拟轴（与 DTS 无关） |
| `slot-power.patch` | 电源键交给前端 |
| `slot-bootlogo.patch` | 把 logo 写回启动分区 |
| `slot-rg353ps.patch` | RG353PS 机型适配（含输入映射、音量） |
| `Dockerfile.slot-build` | 构建用容器 |
| `FRONTENDS.md` | BaseOS 这一侧的前端约定 |

仓库里对应路径是 `platforms/rg353ps/frontends/slot/` 与 `platforms/rg353ps/FRONTENDS.md`。移植时按 `PORTING.md` 的 A→G 顺序做，不要自行发明改动点；摇杆不对时先用 evtest 分层（硬件层 / 前端层），别一上来改代码。

## 10. 待办

### 10.1 产品侧

1. **装载段 ~0.3 s**：raw FIT 固定扇区读取，跳过 bootflow scan 与 FAT 解析。这是启动时间剩下的唯一大块。
2. 内核侧 ~108 ms 可选优化：`CONFIG_CRYPTO_JITTERENTROPY`（70 ms，注意 crng 初始化不能退化）、debugfs 时钟汇总（38 ms）。
3. WiFi 关联与蓝牙音频实机未过；音频出声未验证。
4. 电池/充电读数准确性；HDMI；3D 加速（Panfrost 已装，未证明硬件加速）。
5. s2idle 与 deep suspend 往返（脚本齐备，未系统跑过）。
6. 页面文案：仓库 About 描述已清空，README 与 `platforms/rg353ps/README.md` 部分段落仍停在 A/B 布局之前，需要统一重写。

### 10.2 仓库侧

1. **在本机推进代码前先确认网络**：`curl -sI https://github.com` 能通就直接 `git push`；不通就用下面这套 API 流程（这次就是这么推的，SHA 与本地逐字节一致）：
   - 脚本：移交包内 `工具/push_via_api.py`（本机工作区也留了一份在 `F:\workspace\2026-10-28-22-11-37\.tmp-doc\`）
   - 环境变量：`GH_TOKEN`、`PUSH_BASE=<远端当前 HEAD>`、`PUSH_BRANCH=main`
   - 需要 fine-grained token：Contents / Actions / Workflows 读写（清描述、删分支还要 Administration 写）
2. 发正式版时用 `release` workflow 并填 `release_tag`，产物自动挂 Release。
3. 1.0.1 的旧交付目录（`delivery-1.0.1`、`rg353ps-handoff-20261029-v2`）已被本包取代，注意别拿错镜像。

## 11. 硬约束（别踩）

- 这个 target 必须与 `build-all.sh`、`work/my355` 隔离，Miyoo Flip 的构建路径不能受影响。
- **不要**在 RG353PS 上用 Miyoo 的 preloader 安装器、`mtd5` 补丁、`miyoo355_fw.img`、Android boot image、stock harvest 或 my355 专用 U-Boot 命令。
- U-Boot 的控制 DTB 与 Linux DTB `rk3566-anbernic-rg353ps.dtb` 必须分开。
- 构建脚本只写磁盘镜像文件，绝不打开物理块设备；写卡由人手动做。
- 升级 U-Boot 本身仍需刷整卡（SPL 固定扇区），日常 `.bosupd` 升级不受影响。
- `work/` 是构建产物（约 7–8 GB），不入库，新机器从零构建。
