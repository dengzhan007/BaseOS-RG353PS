# RG353PS 交接说明（1.0.1）

写于 2026-10-30。接手前请先读这一页，再读 `platforms/rg353ps/README.md`（那份是移植本身的说明，部分内容停在 A/B 布局之前，见本文第 7 节）。

---

## 1. 一句话现状

仓库在 `main` 分支上已经能端到端产出 **2 GiB A/B 布局 SD 镜像**和配套 **`.bosupd` 升级包**；1.0.1 的镜像与升级包已构建、已离线逐项校验，**尚未在真机上验证这一版**（真机验证过的是更早的无 A/B 版本，V4L2/手柄/音量/关机都通过）。

## 2. 已交付的东西在哪

`F:\DSH-wordspace\delivery-1.0.1\`

| 文件 | 大小 | 用途 |
|---|---|---|
| `baseos-rg353ps-smoke.img.gz` | 143 MB | 完整镜像，解压 2.0 GiB。**这一版必须整卡刷**（分区表变了） |
| `baseos-rg353ps-1.0.1.bosupd` | 124 MB | 之后的升级只用它，放卡根目录开机自动应用，不刷整卡 |
| `README-烧写与升级说明.txt` | 6 KB | 烧写、升级、WiFi、休眠、bootlogo 的操作说明 |
| `*.sha256` | — | 校验值 |

- 镜像：解压后 `4a145f68a8d6644331269800bcfbb94a9151be7ea69ee1a683138253277e52f5`
- 压缩包：`bbcfa8d2d8fbad9140f5d84ffda46d6280a56caccd52c936141eb145cea29367`
- 升级包：`b8185c23f9d105eb95cfead5534ee035d40b8a83b0f8119e80e3883209f3aaaf`

同一份 zip（`baseos-my355-rg353ps-src.zip`）也在这一层，就是本仓库。

## 3. 在新电脑上恢复环境

**需要**：Linux 或 WSL2（Ubuntu 24.04 实测）、Docker（守护进程可用）、Python 3、Git。x86_64 机器还需要 arm64 模拟：

```sh
docker run --privileged --rm tonistiigi/binfmt --install arm64
```

（`build-rootfs.sh` 要在 arm64 容器里跑 BusyBox 与目标端二进制。Docker Desktop / OrbStack 自带 binfmt，裸 Docker Engine 不带。）

**解压**：用 `unzip` 解，不要用 Windows 资源管理器解压。仓库脚本带可执行位，Windows 解压会丢掉，解出来会全线 `Permission denied`。

```sh
unzip baseos-my355-rg353ps-src.zip
cd baseos-my355
git status            # 应该干净，HEAD = 20ac395
git log --oneline -1
```

如果解压后确实丢了权限，补救：

```sh
find . -name '*.sh' -exec chmod +x {} +
find platforms/rg353ps/rootfs/usr/sbin -type f -exec chmod +x {} +
```

**镜像仓库给了远端**：`origin` 指向 `github.com/dengzhan007/BaseOS-RG353PS`，只有 `main` 一个分支。`.github/workflows/` 里有三个 CI：`rg353ps-uboot.yml`（提交后跑完整构建）、`rg353ps-storage-mode-check.yml`（脚本与嵌入式 Python 语法检查）、`rg353ps-release.yml`（手动触发，产出完整镜像和 `.bosupd` 升级包）。

## 4. 构建怎么跑

仓库里 `work/` 是构建产物（7.4 GB），**没有打进 zip**，新机器从零开始。首次构建需要联网拉：内核 7.2.7 源码、U-Boot v2026.01、rockchip `rkbin`、`linux-firmware` 源码、Docker 基础镜像。合计数 GiB，国内建议配镜像（`ALPINE_MIRROR`、Docker registry mirror、`HTTP_PROXY`）。

在仓库根目录，按顺序：

```sh
./platforms/rg353ps/build-uboot.sh     # idbloader + u-boot.itb → work/rg353ps/rg353ps-uboot.bin
./platforms/rg353ps/build-kernel.sh    # 内核 + DTB + 模块 → work/rg353ps/kernel/output
./platforms/rg353ps/build-firmware.sh  # RTL8821CS 固件 + regulatory.db
./platforms/rg353ps/build-rootfs.sh    # BusyBox 根文件系统 → work/rg353ps/rootfs（arm64 容器）
./platforms/rg353ps/build-image.sh     # 组装 2 GiB 镜像 → baseos-rg353ps-smoke.img
./platforms/rg353ps/build-update.sh    # 生成 .bosupd
```

产物落在 `work/rg353ps/`。内核是整个流程里最慢的一步（本机 24 核，仍以十分钟计）；`build-firmware.sh` 首次要拉 `linux-firmware` 全量源码，约 1.8 GB。

**增量重建**：只改了根文件系统里的脚本，重跑 `build-rootfs.sh` → `build-image.sh` → `build-update.sh` 即可，不必重编内核。只改了 `src/gptslot.c` 这类工具，`build-rootfs.sh` 会重新交叉编译它们。

**磁盘**：`work/` 满配约 7–8 GB，加镜像压缩包约 150 MB，留 12 GB 稳妥。

## 5. 代码地图

```
platforms/rg353ps/
  build-*.sh          六个构建步骤，相互独立，只读写 work/rg353ps/
  kernel/             内核 config、ROCKNIX 补丁源与出处（UPSTREAM.md）、regdb 证书
  patches/            DTS/驱动补丁：面板电源域、DTS 路径、dwc3 ×4、自定义 bootlogo
  rootfs/usr/sbin/    目标机全部工具脚本（见下）
  frontends/          前端适配器（.baseos/frontends/<name>/launch.sh 约定）
src/                  C 工具，交叉编译进 rootfs
  gptslot.c           读/翻 A/B 槽位，唯一的 GPT 写入者
  gptgrow.c           首次开机把 BASEOS_DATA 扩到卡尾
  gpt.h               分区几何常量，改布局从这里起
  fatdirty.c          FAT 非正常卸载检查
  pwrkeyd.c           电源键守护：短按休眠、长按关机
  fbsplash.c          启动 logo 绘制
  rebootmode.c        读 reboot mode
tools/                mkgpt / mkfit / mkupdate / mkbootlogo / source_manifest 等 Python 工具
tests/                纯 shell/python 单测，其中 test-gpt-slot.sh、test-update-*.sh 与 A/B 直接相关
docs/                 上游 BaseOS 的参考文档（Miyoo Flip 视角，仍适用大部分原理）
```

目标机上的关键脚本（`platforms/rg353ps/rootfs/usr/sbin/`）：
`baseos-update`（应用 .bosupd）、`gptslot`（槽位读写）、`baseos-init-userdata`、`baseos-mount-storage`、`baseos-frontend-session`、`baseos-slot-launcher`、
`rg353ps-sleep`、`rg353ps-wifi-connect`、`rg353ps-wifi-cycle`、`rg353ps-hotkeyd`、
`rg353ps-hardware-audit`、`rg353ps-v4l2-report`、`rg353ps-jpeg-encode-test`、`rg353ps-graphics-stack-test`、`rg353ps-suspend-audit`、`rg353ps-suspend-test`、`rg353ps-suspend-deep`。

## 6. 磁盘布局（1.0.1 起）

| 分区 | 起止 LBA | 大小 | A/B |
|---|---|---|---|
| `BASEOS_UBOOT` | 16384 | 8 MiB | **否**，SPL 按固定扇区读，永不搬 |
| `BASEOS_BOOT` | 32768 / 备用 294912 | 128 MiB | 是 |
| `BASEOS_ROOT` | 557056 / 备用 1605632 | 512 MiB | 是 |
| `BASEOS_DATA` | 2654208 → 卡尾 | 首次开机扩展 | 否，用户数据 |

备用半区**故意不建分区**：不占分区号，桌面系统不会提示格式化，翻转时分区号不位移。所有区域从 LBA 16384 起前向平铺、首尾相接，`BASEOS_DATA` 正好落在最后一个备用半区之后——这些不变量写在 `src/gptslot.c` 的注释里，改布局必须一起改。

`gptslot` 同时接受 GPT 分区名（`BASEOS_ROOT`）和逻辑名（`rootfs`），大小写不敏感；`baseos-update` 传的是逻辑名。

## 7. 文档需要你知道的滞后

- `platforms/rg353ps/README.md` 里"256 MiB FAT boot + 1280 MiB root、无 A/B、无更新器"那段是 1.0.0 之前的状态，**已过时**。以本文第 6 节为准。
- 上游 `README.md` / `docs/` 讲的是 Miyoo Flip（my355），原理仍适用，但分区号、路径、工具名不要照抄。
- 镜像 build-id 为 `16652d2-dirty-20261030080107`，带 `dirty` 后缀说明构建时工作区有未提交改动，**与当前 HEAD（20ac395）不是逐字节可复现的关系**。要严格可复现，从当前 HEAD 重新构建一次再发。

## 8. 待办（真机验证清单）

按优先级：

1. **本版 A/B 布局在真机上跑通**：刷整卡 → 确认首次开机 `BASEOS_DATA` 扩展到卡尾 → 放一个 `.bosupd` 到卡根 → 重启应用 → 确认槽位翻转、系统正常、存档还在。这一条是本版最大的未验证项。
2. WiFi 关联（`rg353ps-wifi-connect join`）与蓝牙音频，实机未过。
3. 音频播放本身（RK817 音量调节已验证，出声未验证）。
4. 电池/充电读数准确性。
5. HDMI、3D 图形（Panfrost/Mesa 栈已装，未证明硬件加速）。
6. s2idle 与 deep suspend 的实机往返（脚本齐备，`rg353ps-suspend-test` 未跑过）。
7. 长时稳定性与存储寿命。
8. 尚未做：只读根、正式发布打包。

## 9. 踩过的坑（直接省你时间）

- **`sh -euc '...'` 里不能出现英文撇号**。注释里写 `platform's` 会把引号撕裂，报错信息指向很远的行。容器脚本段一律避开撇号。
- **绝对符号链接的 `[ -e ]` 判定**。rootfs 里 `/bin`、`/sbin` 链到 `/usr`，applet 链到 `/usr/bin/busybox` 用的是绝对路径，host 侧解析必然失败，会误报"缺 sbin/init"。已改为 `[ -e ] || [ -L ]`。
- **`baseos-release` 的校验语句必须排在生成它的 heredoc 之后**，否则每次构建都在收尾处中止。
- **`gptslot` 曾经只认 GPT 分区名**，而 `baseos-update` 传逻辑名，导致设备端每次升级都被拒绝翻转。现在两者都认。
- **在 WSL 里看镜像内容**：loop mount 常不可用。切分区 + `debugfs`（ext4）/ `mdir`·`mcopy`（FAT，需 `apt install mtools`）最省事：
  ```sh
  dd if=baseos-rg353ps-smoke.img of=/tmp/p3.ext4 bs=512 skip=557056 count=1048576 status=none
  debugfs -R "ls -l /etc/baseos" /tmp/p3.ext4
  debugfs -R "stat /usr/sbin/gptslot" /tmp/p3.ext4
  ```
  注意 `sizelimit`/`count` 单位是 512 字节扇区。
- **不要在 Windows 侧解压或编辑仓库**：可执行位丢失、CRLF 混入，`sh` 脚本会以 `\r` 报错。

## 10. 硬约束（别踩）

- 这个 target 必须与 `build-all.sh`、`work/my355` 隔离；Miyoo Flip 的构建路径不能受影响。
- **不要**在 RG353PS 上用 Miyoo 的 preloader 安装器、`mtd5` 补丁、`miyoo355_fw.img`、Android boot image、stock harvest 或 my355 专用的 U-Boot 命令。
- U-Boot 的控制 DTB 与 Linux DTB `rk3566-anbernic-rg353ps.dtb` 必须分开。
- 构建脚本只写磁盘镜像文件，绝不打开物理块设备；写卡由人手动作业。
- 升级 U-Boot 本身仍需刷整卡（SPL 固定扇区），日常升级不受影响。
