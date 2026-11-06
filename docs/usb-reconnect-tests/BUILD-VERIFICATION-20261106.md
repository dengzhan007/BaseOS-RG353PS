# RG353PS USB OTG 重连诊断 — 检查 / 测试 / 构建验证报告

- **日期：** 2026-11-06
- **分支：** `usb-reconnect-diag`
- **commit：** `3bc1d3d`（VERSION 1.2.4）
- **执行方式：** 本地自动化（Agent 模式，只读/检查 + 完整内核构建 + 产物验证）
- **约束遵守：** 未切换或合并 `main`；未修改 DWC3 / USB PHY / Supervisor 功能逻辑；未删除诊断代码、动态调试规则或文档；未改动 USB 恢复策略；未创建 Release、未发布镜像、未刷机。

---

## 1. 仓库分支、commit 与工作区状态

| 项目 | 结果 |
|---|---|
| 当前分支 | `usb-reconnect-diag`（确认，未切换） |
| commit | `3bc1d3d`（VERSION=1.2.4） |
| 远端同步 | 已 `git fetch --all --prune`，与远端 `usb-reconnect-diag` 同步（0 ahead / 0 behind） |
| 工作区 | 干净（0 未提交修改）；Windows 侧仓库全程未改动，仅单向同步到 WSL 构建目录 |
| 6 个必需文件 | 全部存在 |

必需文件核对：

- `platforms/rg353ps/kernel/tools/inject-reconnect-diag.py` ✅
- `platforms/rg353ps/build-kernel.sh` ✅
- `platforms/rg353ps/tools/usb-reconnect-diag.sh` ✅
- `platforms/rg353ps/tools/test-kernel-input-key.sh` ✅
- `platforms/rg353ps/tools/test-usb-reconnect-diag-awk.sh` ✅
- `docs/usb-reconnect-tests/INSTRUMENTATION-VALIDATION-20261105.md` ✅

---

## 2. 两个回归测试结果

### 2.1 `test-usb-reconnect-diag-awk.sh` — 全部 PASS（24 / 0）

kmsg 过滤、IRQ 快照、空输入 → N/A、上限截断等断言全部通过。

### 2.2 `test-kernel-input-key.sh` — 前 2 条 PASS，第 3 条 FAIL（非功能问题）

| 断言 | 结果 |
|---|---|
| 注入器路径固定 | PASS |
| 缺失 / 空注入器时构建失败退出 | PASS |
| `injector content is hashed with baseos_sha256` | **FAIL** |

**失败说明（非功能问题）：** 测试期望字面串 `INJECTOR_SHA="$(baseos_sha256 "$INJECTOR)"`，但 `build-kernel.sh` 第 76 行实际写法是 `INJECTOR_SHA="$(baseos_sha256 "$PLATFORM_DIR/kernel/tools/inject-reconnect-diag.py")"`（内联完整路径，未复用 `$INJECTOR` 变量）。两者对**同一文件**取 SHA256，所以「注入器内容参与缓存键、改动即失效」这一行为**实际正确**，只是测试与实现对字面值要求不一致。

**影响评估：** 纯测试/实现字面漂移，不影响构建正确性，也不影响「改 injector 内容会改变缓存键」这一核心断言（见第 4 步缓存验证）。按「不擅自扩大修改范围」本次未改任何代码。

---

## 3. 9 个诊断注入点检查（含实际运行注入器）

在 WSL 构建环境中用缓存的 `linux-7.2.7` 干净源码实际跑了一遍注入器（即构建容器内会执行的步骤），提前暴露锚点匹配问题。

| 检查项 | 结果 |
|---|---|
| 9 点定义完整 | `gadget.c` 8 个（DISCONNECT / PULLUP×4 / SOFTCONNECT×3）+ `udc/core.c` 1 个（UDC connect out） |
| 锚点匹配 7.2.7 源码 | 实跑注入器返回 `Applied RG353PS DWC3 RECONNECT low-frequency diagnostics`，标记数 = 9，无「锚点不唯一」报错 |
| 幂等 | 第二次运行标记数仍为 9，无重复插入 |
| 无逻辑改动 | 9 条带前缀行**全部是 `dev_dbg`**（PREFIX_LINES=9 = DEV_DBG_LINES=9）；原函数签名 `dwc3_gadget_disconnect_interrupt` / `dwc3_gadget_soft_connect` 仍存在且唯一 |
| 动态调试规则覆盖 | `usb-reconnect-diag.sh` 第 174–177 行用 4 条 `format "RG353PS DWC3 RECONNECT {DISCONNECT|PULLUP|UDC|SOFTCONNECT}" +p` 恰好覆盖 9 点（1+4+1+3）；第 186–189 行有对应 `-p` 关闭规则 |

---

## 4. 完整内核构建

| 项目 | 内容 |
|---|---|
| 结果 | **成功（BUILD_EXIT=0）** |
| 分支 / commit | `usb-reconnect-diag` @ `3bc1d3d`，VERSION 1.2.4 |
| 内核 | `linux-7.2.7`，`ROCKNIX_REF=becc8cb2a97b8b44b25d39dd5b6aa8f77b0af1c5`，release `7.2.7-baseos-rg353ps` |
| 命令 | `sh platforms/rg353ps/build-kernel.sh`（在 WSL `/root/work/baseos-123`，已单向同步当前分支） |
| 起止时间 | 2026-11-06T00:55:02Z → 00:59:29Z（约 4m27s） |
| 日志 | `/root/work/baseos-123/build-rg353ps-diag.log`（5286 行） |
| 注入器执行确认 | 日志第 617 行 `Applied RG353PS DWC3 RECONNECT low-frequency diagnostics` |
| 缓存命中 | 160MB 内核包**缓存命中未重新下载**（日志无 "downloading Linux"）；因当前 `build-kernel.sh` + 注入器哈希变化使 `INPUT_KEY` 失效，源码被**重新解包 + 完整重编译**——正好证明「改 injector 内容会改变缓存键」的回归断言成立 |

> 注：OTG 事件驱动补丁（`build-kernel.sh` 内 `peripheral` 改写）为该分支既有内容，本次一并编入内核，未做改动。

---

## 5. 构建产物与 SHA256

路径：`/root/work/baseos-123/work/rg353ps/kernel/output/`

| 产物 | 大小（字节） | SHA256 |
|---|---:|---|
| Image | 21,702,664 | `d6b66d7eee39f08ea577f0f1506f3c54d34e7ad8fd61c09ed815fa43250a6cad` |
| rk3566-anbernic-rg353ps.dtb | 64,329 | `1abc0983b96309e1ca1d4cd590f23b0032d74dc40736af757b1de23ff3fc4d8d` |
| modules-7.2.7-baseos-rg353ps.tar.zst | 3,232,013 | `e158055ecf9426b65ada6370611df742981478694a870df9e7a6e4d51b34f128` |
| System.map | 4,023,766 | `50e86f9613b9a82b3df46ee6e31d96cebcb4fa35c9da3c1b4fe400818ea15632` |
| linux.config | 185,683 | `56309d20398940e07bf59699ee1e97e1d40b450b7a792258856fd24c5ae7dfb7` |
| Module.symvers | 749,432 | `845f2168152362ee90b1bb988150b3c25676f1787459b0b1a0e345526465e0db` |
| kernel-build.json | 1,119 | `48eb9ce952478fd3e270abc7cccf5164db2796acf6ac328bfab3531eba1fa04e` |

---

## 6. 诊断代码是否进入最终内核 — **已确认**

直接检查编译产物目标文件（这两个 `.o` 会被链接进内核 Image）：

| 目标文件 | 含诊断字符串数 |
|---|---:|
| `drivers/usb/dwc3/gadget.o` | 8 |
| `drivers/usb/gadget/udc/core.o` | 1 |
| **合计** | **9 / 9** |

与最终源码标记数（`gadget.c`=8 / `core.c`=1）完全一致，且 `.o` 为本次构建新生成（Nov 6 08:58）。**仅凭注入器执行成功不足以判定，已通过目标文件内 `strings` 校验确认 9 点全部进入最终内核。**

---

## 7. 仍存在的风险与未验证事项

1. **`test-kernel-input-key.sh` 断言 3 字面不匹配**：CI 若按「全绿」判定会误报失败。建议后续把 `build-kernel.sh` 第 76 行改为复用 `$INJECTOR` 变量以与测试一致——本次按「不擅自扩大修改范围」未改。
2. **本次仅构建内核 bundle，未做 rootfs / uboot / 镜像打包**，未刷机、未发布。
3. **未做真机硬件实测**（`kernel-build.json` 中 `hardware_tested=false`）：诊断点已编译进内核，但需在设备端用 dyndbg 打开后才能看到日志并验证重连行为。
4. **已知未修项仍在**：supervisor 的 `stuck-at-default` 盲区（键盘线卡 `default` 61.6s 零恢复）本次未触碰，预期真机仍会复现。

---

## 8. 下一步需要你在 RG353PS 上执行的操作

1. **部署内核**：本次只产出内核 bundle（非完整镜像），需走现有 A/B 升级或手动替换 `/boot` 的 `Image` + `dtb` + `modules`。**未自动刷机**。校验值见第 5 节。
2. **开启诊断并验收**：设备启动后用 `usb-reconnect-diag.sh` 的 dyndbg 开启命令（`format "RG353PS DWC3 RECONNECT *" +p`）打开 9 个诊断点，做拔插测试，确认 `dmesg` 出现 DISCONNECT / PULLUP / SOFTCONNECT / UDC 各点日志。
3. **继续重连矩阵**：按之前交接文档，在另一台电脑用**线 1（好数据线）/ 线 3（手机线）**做交叉测试，**勿用线 2（键盘线）**。
4. **复验键盘线盲区**：新内核未改 supervisor，预期 `stuck-at-default` 仍会复现；若复现，建议后续单独补 supervisor 超时恢复补丁（不在本次范围）。

---

## 附：辅助脚本与日志位置（Windows 侧，非仓库内）

- `F:/Workbuddy-workspace/{sync-repo,run-build,step3-inject-check,verify-kernel,docker-start,docker-net-test}.sh`
- 完整构建日志：WSL `/root/work/baseos-123/build-rg353ps-diag.log`
