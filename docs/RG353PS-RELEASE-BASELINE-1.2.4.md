# RG353PS 1.2.4 发布基线与 USB 重连验证结论

**状态：候选基线已冻结；尚未创建正式 Git tag 或 GitHub Release。**  
**文档维护位置：** `main`  
**功能源码基点：** `main` / `507004ee49d12ac7088ad4110afa97f43e77612b`  
**VERSION：** `1.2.4`  
**内核候选标识：** `bvalid-otg-sm-serialized-v1`  
**冻结日期：** 2026-11-06

## 1. 冻结决策

当前 RG353PS 的后续发布候选以 `main@507004e` 为功能代码基线。此后 main 上新增的本轮整理提交仅更新文档，不改变该功能代码基线。该提交包含当前内核候选、USB RNDIS/MTP 管理与 Supervisor 兜底恢复逻辑；不包含专门用于本轮取证的 DWC3 诊断注入代码。

本次冻结只记录和固化现有行为，不新增 USB 功能、不改内核状态机、不改 Supervisor 恢复阶梯、不改 DHCP、VBUS、Runtime PM 或 gadget 配置。

**不要将 `usb-reconnect-diag` 分支直接作为正式发布源码。** 该分支比 `main` 多 16 个提交，差异包含：
- 在 DWC3/gadget/UDC 调用路径中注入 9 个低频 `dev_dbg` 观测点；
- 诊断采集脚本、动态调试规则、回归测试和诊断文档；
- 39 轮有效测试的逐轮 CSV 与原始日志。

注入器新增的是日志观测，不应改变 USB 恢复策略；但诊断内核不是干净发布产物。正式镜像应从 `main` 的干净源码重新走正常构建流程，不应复用诊断分支本地构建产生的 dirty 镜像或更新包。

## 2. 源码与构建证据

### 2.1 源码关系

- 功能代码基线：`507004ee49d12ac7088ad4110afa97f43e77612b`。
- 完整 Release 构建运行于 `eeaca5f48d54862171452f76cdc1a962db7c2af2`。
- 两个提交之间只存在一处 `platforms/rg353ps/USB.md` 文档差异：将硬件检查清单中的“至少重复 20 次”改为“完成 2 主机 × 2 线材矩阵，每组合 10 轮”。构建脚本和功能代码未变。
- `platforms/rg353ps/build-kernel.sh` 中记录的内核候选为 `bvalid-otg-sm-serialized-v1`。

### 2.2 GitHub Actions

| 工作流 | Commit | 结果 | 说明 |
|---|---|---|---|
| RG353PS release build | `eeaca5f` | PASS | U-Boot、固件、内核/DTB/modules、release rootfs、SD 镜像、`.bosupd`、校验文件均完成 |
| RG353PS bring-up build | `507004e` | PASS | U-Boot、固件、内核、rootfs、smoke image 完成 |
| RG353PS USB storage mode checks | `507004e` | PASS | Shell/Python 静态检查与相关测试通过 |

Release workflow：
https://github.com/dengzhan007/BaseOS-RG353PS/actions/runs/41973900478

Bring-up workflow：
https://github.com/dengzhan007/BaseOS-RG353PS/actions/runs/41973910453

USB storage checks：
https://github.com/dengzhan007/BaseOS-RG353PS/actions/runs/41973910452

Release workflow 上传的 Actions artifact 为 `baseos-rg353ps-1.2.4`（artifact ID `13391094345`，整体 ZIP digest `sha256:b61249b9d95a04242d16c9b7bacfe59f66808e95770f12a8bb97478b99c6ded1`）。截至本基线冻结时，GitHub Releases 列表为空，工作流中的“Attach artifacts to a release”步骤为 skipped；因此这只是成功构建产物，不代表已正式发布。该 Actions artifact 有保留期限（记录到期日 2026-12-05），最终发布前应重新构建并重新校验，不要依赖临时 Actions artifact 作为长期分发源。

## 3. USB 重连 40 轮复测：权威统计口径

详细报告、逐轮数据与原始日志保存在诊断分支：
- 最终报告：[RESULT-40round.md](https://github.com/dengzhan007/BaseOS-RG353PS/blob/usb-reconnect-diag/docs/usb-reconnect-tests/40round-20261106/RESULT-40round.md)
- 逐轮数据：[cycles.csv](https://github.com/dengzhan007/BaseOS-RG353PS/blob/usb-reconnect-diag/docs/usb-reconnect-tests/40round-20261106/cycles.csv)
- 原始采集目录：[40round-20261106/raw](https://github.com/dengzhan007/BaseOS-RG353PS/tree/usb-reconnect-diag/docs/usb-reconnect-tests/40round-20261106/raw)

### 3.1 有效样本

本轮总计划 40 轮，其中 PC-B 第 30 轮因主机断电而作废。主统计采用 39 个有效样本：
- PC-A：run2 的 20 轮权威数据；
- PC-B：19 个有效样本（线3 9 轮、线1 10 轮）。
- PC-A run1 的 20 轮单独保留为历史重复/对照，不混入 39 轮主统计；其第 7 轮出现过 WARN 风暴与 APIPA，诊断日志也因当时 20,000 行上限而截断。run2 提高上限后未复现该问题。

### 3.2 四组结果

| 主机 / 线材 | 有效轮次 | Supervisor re-probe | 比例 |
|---|---:|---:|---:|
| PC-A + 线1 | 10 | 8 | 80% |
| PC-A + 线3 | 10 | 0 | 0% |
| PC-B + 线1 | 10 | 2 | 20% |
| PC-B + 线3 | 9 | 0 | 0% |
| **合计** | **39** | **10** | **25.6%** |

- 39/39 在 20 秒观察窗口内恢复到可用状态。
- RNDIS、DHCP、MTP 主机侧检测均为 39/39 成功。
- 39 个有效样本内没有 APIPA/DHCP 失败，也没有复现 `gadget.c:2076` WARN 风暴。
- Path A（Supervisor DWC3 re-probe）10/39；Path B（无 Supervisor re-probe 的自恢复）29/39。
- Path A 约 9–11 秒；Path B 约 1–5 秒。
- 插入时 UDC 为 `not attached` 与需要 re-probe 高度关联；`configured`/`addressed` 场景均在本轮中自恢复。

旧版独立基线为 19/40（47.5%）需 re-probe；本轮主统计为 10/39（25.6%）。这只能作为观察值对比，不能把比例下降单独归因于内核序列化改动，因为本轮并非对相同主机、相同端口、相同线材进行严格的代码 A/B 对照。

## 4. 线材判断与工程处理

本轮最稳定的关联是线材：
- PC-A：线1 为 8/10 re-probe，线3 为 0/10；
- PC-B：线1 为 2/10，线3 为 0/9；
- 用户实物观察：线1 明显长于线3；
- 逐轮 PHY 日志显示线1更容易出现额外 BVALID 跳变，线3的有效轮次没有同类额外跳变。

据此，当前工程处理决定：
1. 将线1标记为**疑似电气特性不佳的长线**，不再用作内核验收的参考线。
2. 线3作为当前参考线；新增短款、可靠的 USB 2.0 High-Speed 数据线通过 PC-C 对照测试后，可加入参考线清单。
3. 现有证据足以支持停止为线1单独调整内核；继续保留 Supervisor re-probe 兜底。
4. 不宣称已测得线1电阻超标或 VBUS 压降超标。当前没有四线电阻测量、VBUS 瞬态波形或线缆规格数据，因而不能把“长度/线阻”写成已经证实的物理根因。
5. 后续如有需要，PC-C 同机对照只用于补强线材归因，不作为继续修改 PHY/DWC3 的默认触发条件。

## 5. 真机测试内核与正式镜像的区别

39 轮复测运行在 RG353PS 真机，内核版本为 `7.2.7-baseos-rg353ps`，测试构建标识为 `aa3536b-dirty-20261106013813`。

该测试镜像来自 `usb-reconnect-diag`：其功能代码基于上述内核候选，额外增加 9 个 DWC3/gadget/UDC `dev_dbg` 观测点，并使用只读采集脚本。诊断代码的运行时作用是记录调用路径，不负责恢复设备，也没有改变 Supervisor 策略。9 个动态调试选择器启用成功；9 个 DWC3 注入点中 8 个在 5 轮早期专项测试中实际命中，`PULLUP short` 观察点未命中。40 轮报告应以实际命中记录为准，不把“规则开启”说成“每个调用点均执行”。

测试构建 ID 含 `-dirty`，构建验证报告记录其来源是 WSL 构建副本中的临时 uMTP clone URL 镜像替换，没有进入提交。因此：
- 该镜像可作为功能行为的硬件测试证据；
- 不应把它当成干净、可复现的正式发布产物；
- 正式镜像应从 `main` 的功能代码基线重新构建；
- 诊断注入器与诊断采集脚本不进入正式发布构建。

## 6. 版本冻结范围与保留项

**本次不修改：**
- Rockchip USB2PHY / OTG 状态机；
- DWC3 gadget / UDC 连接逻辑；
- Supervisor 的恢复时序、re-probe 顺序及兜底策略；
- RNDIS、DHCP、MTP、Mass Storage 的配置与分区边界；
- U-Boot/SPL、A/B 更新机制及用户数据分区。

**明确保留：**
- 当前 Supervisor DWC3 re-probe 作为处理 `not attached` 的可用兜底；
- 当前 `bvalid-otg-sm-serialized-v1` 内核候选；
- 当前 USB 开发/发布 profile；
- MTP 与 Mass Storage 的既有隔离、安全边界。

**仍未由这轮重连矩阵覆盖的 USB 验证项：**
- 大文件双向传输的字节级完整性；
- 中文名、空格、深层路径、创建/重命名/删除等 MTP 文件操作；
- MTP-only 正式发布 profile 的真机枚举；
- 意外拔线后的长时间压力与反复恢复；
- Mass Storage 多轮进入/退出的完整真机回归。

因此，本文件冻结的是**USB 重连与当前功能代码的候选基线**，不是对所有 USB 功能完成全面硬件认证的声明。

## 7. PC-C 补充对照（待用户回家后执行，非代码冻结阻塞项）

目标：同一台 PC-C 上对照原线1与一根全新、短款、明确支持 USB 2.0 High-Speed 数据传输的线材，各 10 轮。

建议采用两个相邻主板 USB 口：
1. 第一阶段：线1使用端口 A、新线使用端口 B，各做 5 轮；
2. 第二阶段：交换两根线的电脑端端口映射，各做 5 轮；
3. RG353PS 端每次只连接其中一根线，另一根设备端保持悬空；不要通过 HUB/扩展坞；
4. 不改变设备内核、USB profile、测试节奏或 Supervisor 策略；不手动 soft_connect/re-probe；
5. 记录线材长度、接口/线型、PC-C 型号和系统版本、端口位置、UDC 状态、BVALID 次数、Supervisor re-probe、RNDIS/DHCP/MTP 结果。

解释边界：
- 若线1在端口 A/B 都明显高于新线，可进一步强化线材归因；
- 若异常跟着端口而不是线材走，应重新考虑主机端口因素；
- 即使 PC-C 没有复现，也不推翻 PC-A/PC-B 的现有观测，只说明主机/端口条件会影响触发概率。

PC-C 结果作为后续补充记录到测试报告，不自动触发内核改动。除非发现线3/新线也出现实际连接失败或其他可复现的功能性问题，否则保持本候选基线不变。

## 8. 发布动作约束

本次将候选基线报告与修订后的 USB 文档归档到 `main`，仅有文档变化：
- 不创建 `v1.2.4` 标签；
- 不创建 GitHub Release；
- 不把诊断分支合并到 `main`；
- 不发布现有 dirty 诊断镜像；
- 不覆盖或删除任何原始测试日志。

正式发布前，从 `main` 干净源码重新执行 Release workflow，保留镜像、更新包、校验文件和 build metadata；再依据剩余硬件验收范围决定是否发布。


## 9. 仓库分支清理记录（2026-11-06）

本轮分支盘点结果：

| Branch | 相对 main | 处理 |
|---|---|---|
| `main` | 功能代码基线 | 保留；后续 USB 与基线文档已归档在此 |
| `feature/rg353ps-usb-mtp-composite` | 0 ahead / 21 behind | **可删除**；提交全部已在 main 中，不含独有工作 |
| `release/rg353ps-1.2.4-baseline` | 2 ahead / 4 behind；两个独有提交仅为此前创建的基线文档 | **可删除**；没有独有功能代码 |
| `usb-reconnect-diag` | 16 ahead / 4 behind | 保留为诊断证据分支，含注入器、脚本、逐轮 CSV 和原始日志 |
| `slot6-rg353ps-bringup` | 25 ahead / 81 behind，已分叉 | 保留；PR #4 仍开放，含 Slot-6 前端适配的独有提交 |

没有 GitHub Release 或版本标签。PR #4（Slot-6 bring-up）仍开放；其余已关闭/合并 PR 记录保留。不得删除 `usb-reconnect-diag` 的测试资料，也不得删除 Slot-6 分支或关闭 PR #4 来代替正常审查。

本轮不删除 main 中的 `overlay-diag/`、`tools/uboot/*diag*` 或 RG353PS 根文件系统中的手动诊断工具：前两者被 MY355 诊断构建路径使用；后者是显式调用的硬件维护工具，不在正常启动流程中执行。main 目前没有误入的 USB 测试原始日志或 DWC3 诊断注入器。构建产物由 `.gitignore` 排除，当前 main 树没有镜像、压缩包、日志或其他构建产物。
