# RG353PS USB OTG 真实拔插诊断报告

**状态：已完成一次真实硬件拔插采集**（本文件不是测试准备说明，也不是模拟数据）。

## 1. 基线信息

| 项 | 值 |
|---|---|
| 分支 | `usb-reconnect-diag` |
| 诊断脚本 commit SHA | `f325044e00152f524fbdd395f37f766b406dc2f6`（本轮测试前的分支 HEAD） |
| 脚本文件 | `platforms/rg353ps/tools/usb-reconnect-diag.sh`（v1.1，60 秒默认配置，无任何环境变量覆盖） |
| 脚本 SHA256 | `1afb5ceb7fec378423178d3f252019cbf22f1febc09efd47e388f7ef7d723800` |
| 设备 | Anbernic RG353PS，BaseOS `1.2.4` / `67f86b1` |
| 内核 | `Linux BaseOS-RG353PS 7.2.7-baseos-rg353ps #1 SMP PREEMPT Thu Nov 5 05:18:47 UTC 2026 aarch64` |
| 采集时间（设备 UTC） | 2026-11-05 14:36:34 → 14:37:35（61 秒；北京时间 22:36:34 → 22:37:35） |
| 日志文件 | `usb-reconnect-diag-20261105-143634.log`（73,893 字节 / 329 行 / SHA256 `10a620bd98dc2a4f4fc398e10085c189baeaff568f104b3d844ac07787b29d35`） |
| 采集参数 | 60 s、采样间隔 0.5 s、上限 20000 行、`kernel_stream=/proc/kmsg`、`debugfs_mounted_by_script=1` |

## 2. 拔插过程（人工操作，Agent 只做启动与取证）

1. 脚本由 Agent 通过 SSH 以 `nohup` 后台方式启动，脱离 SSH 会话（拔线会断开 RNDIS/SSH）。
2. 确认终端出现 `CAPTURE STARTED`，日志路径 `/mnt/SDCARD/usb-reconnect-diag-20261105-143634.log`。
3. Agent 提示用户拔线；用户确认「已拔掉」（本地时间 22:36:51）。
4. Agent 等待约 3 秒（22:36:51 → 22:36:54）后提示插回。
5. 用户确认「已插回」（本地时间 22:37:20；设备侧在 14:37:07 已检测到 VBUS 上升，用户回复存在交互延迟）。
6. **未执行任何人工恢复动作**，等待 60 秒采集自然结束，之后才连回设备取日志。

> 设备自身的 `baseos-usb-debug` supervisor 按既有策略**自动**执行了一次 re-probe（见 §4）。这是设备原有行为，不是本次测试注入的操作。

## 3. 证据来源与时钟说明

- **主证据**：诊断日志中的 `[kmsg]` 内核事件、`[sample]` 每 0.5 秒的 UDC/extcon/IRQ 快照、头尾快照。
- **补充只读取证**：采集结束后查询设备 `/run/baseos-usb-debug.log`（supervisor）、`/run/baseos-dnsmasq.log`（DHCP），以及 Windows 侧 `Get-NetIPAddress`（RNDIS）。这三项**不在诊断日志内**，报告中单独标注来源。
- 内核 printk 时间戳（9399–9458 单调秒）与设备 `/proc/uptime`（29400 秒）基准分叉约 2 万秒（该平台 suspend 后两条时钟不同步），因此**未做绝对换算**。内核事件用「紧邻的前一次 `[sample]` 墙钟」标注，误差 ≤ 0.5 秒；两个时间轴的内部跨度一致（59 秒内核跨度对应 60 秒采集窗口）。
- `/proc/kmsg` 在打开瞬间会吐出少量历史积压消息（内核时间 8700–9403 的 `callbacks suppressed` 等），这些不是本次拔插事件，未纳入时间线。

## 4. 完整事件时间线（设备 UTC）

| 时刻 | 阶段 | 事件与证据 |
|---|---|---|
| 14:36:35–14:36:48 | **拔出前** | UDC `configured / high-speed / high-speed`，EXTCON_USB=1；EP0 SETUP 周期性成对出现（`type=21` + `type=a1`，每约 2.5 秒一对）；USB2PHY IRQ20=189，DWC3 IRQ31 从 67120 缓慢增长到 67208 |
| **14:36:49** | **拔出** | DWC3 device-event raw seq 1–8 → `RG353PS DWC3 device DISCONNECT event speed=3 link_state=3 connected=1 setup_pending=0`；BVALID IRQ `irq=20 pending=1 mode=2 state=3 bvalid=0`；`USB PHY VBUS-valid IRQ observed`；OTG 状态机 entry ×2；`OTG VBUS decision ... old=1 new=0`；`extcon notify before cable=5 vbus=0 usb=1`；`extcon charger result state=0 ret=0`；**`extcon data result usb=0 ret=0`（EXTCON_USB 1→0）**；IRQ20 189→190；IRQ31 67216 |
| 14:36:49–14:37:07 | **拔出期间（约 18 s）** | UDC `not attached`，EXTCON_USB=0，**无 EP0 SETUP**（9415–9435 内核秒区间为 0 条）；IRQ20 190→192（VBUS 抖动），IRQ31 67216→67218 基本停滞；supervisor `14:36:49 cable removed (state=not attached)` |
| **14:37:07–14:37:08** | **重新插入 / PHY 层** | BVALID IRQ 连续 3 次（9430.453 `bvalid=1`、9430.498 `bvalid=0`、9431.199 `bvalid=1`，插入抖动）；OTG 状态机多次 entry；`USB PHY OTG sample mode=2 state=1 bvalid=1 suspended=0 host_extcon=0`；DWC3 仍出现一次 `device DISCONNECT event speed=0 connected=0`；`OTG VBUS decision chg_state=5 chg_type=4 old=0 new=1`；`extcon notify before cable=5 vbus=1 usb=0`；`extcon charger result state=1 ret=0`；**`extcon data result usb=1 ret=0`（EXTCON_USB 0→1）**；IRQ20 192→193；IRQ31 67218 |
| 14:37:08 | **状态检查点** | `[sample]`：EXTCON_USB=1，但 **UDC 仍 `not attached`**；supervisor `cable inserted (state=not attached)` |
| **14:37:10** | **supervisor 介入** | `/run/baseos-usb-debug.log`：`launching asynchronous recovery attempt 1`（设备既有策略自动触发，非人工） |
| 14:37:09–14:37:14 | **延迟窗口** | OTG 状态机 entry + `OTG sample state=3 bvalid=1`；UDC 持续 `not attached`；IRQ20=193 稳定，IRQ31 一度采样为 `N/A`（原因未知），14:37:14 回到 67220 |
| **14:37:14** | **DWC3 响应 / 枚举** | device-event raw seq 11 `link_state=4 connected=0`、seq 12 → **`RG353PS DWC3 device RESET event`**、seq 13 `connected=1`；**EP0 SETUP 突发 55 条**（9435–9440 内核秒区间）；dnsmasq `14:37:14 DHCPREQUEST / DHCPACK`（补充取证，主机拿到固定地址、非 APIPA） |
| **14:37:15** | **恢复完成** | UDC `configured / high-speed`，IRQ31 67482→持续快速增长；supervisor `re-probe done state=configured` / `attempt 1 done`；EXTCON_USB=1 |
| 14:37:15–14:37:35 | **恢复后** | UDC 保持 `configured / high-speed`；EP0 SETUP 恢复为每 5 秒 4 条的周期轮询，持续到采集结束（9458.10）；IRQ31 增长到 67716，IRQ20 保持 193；OTG 状态机在 14:37:18 仍有一次 entry；采集结束后 SSH 可连回，Windows 侧 RNDIS `Up / 426 Mbps`、IPv4 `origin=Dhcp`（补充取证） |

**关键时间差**：EXTCON_USB 上升（14:37:08）→ UDC `configured`（14:37:15）约 **7 秒**；其中约 2 秒是 supervisor 等待后发起 re-probe，约 5 秒是 re-probe 与重新枚举。

## 5. 八个取证点小结

1. **VBUS / BVALID**：拔出 `bvalid=0`（9412.769），插入 `bvalid=1`（9430.453 / 9431.199），中间有 `bvalid=0` 抖动（9430.498）。BVALID IRQ 共 4 次。
2. **Rockchip USB2PHY IRQ20**：189（初始）→ 190（拔出）→ 192（插入抖动）→ 193（稳定）；IRQ21 恒为 0；DWC3 IRQ31 67120 → 67218（拔出期间停滞）→ 67482（枚举开始）→ 67716（结束）。
3. **OTG 状态机**：9 次 entry，含拔出 2 次、插入 5 次、恢复后 2 次；`OTG VBUS decision` 4 次（拔出 `old=1 new=0`、插入抖动 `old=0 new=0` ×2、最终 `old=0 new=1`）；`OTG sample` 2 次（`state=1` / `state=3`）。
4. **EXTCON_USB**：1 → 0（14:36:49）→ 1（14:37:08），`extcon data result` 两次均 `ret=0`，采样值同步翻转。
5. **DWC3 事件**：DISCONNECT ×2、RESET ×1、device-event raw ×13（seq 1–13）；插入后直到 re-probe 之前**没有任何 DWC3 connect 类事件**。
6. **EP0 SETUP**：共 83 条。拔出前周期轮询、拔出期间完全中断、14:37:14 突发 55 条、之后恢复周期轮询。
7. **UDC**：`configured/high-speed` → `not attached`（约 26 s）→ `configured/high-speed`；`maximum_speed` 全程 `high-speed`。
8. **三段对应关系**：见 §4 表格，拔出前后与插入后各阶段均有采样与内核事件双重证据。

## 6. 分层判断（明确区分五类情形）

| 情形 | 本次结论 | 依据 |
|---|---|---|
| A. USB PHY 未检测到重新插入 | **否** | BVALID IRQ `bvalid=1`、VBUS-valid IRQ、`OTG sample bvalid=1` 明确出现，IRQ20 增加 |
| B. PHY 检测到了，但状态机没有正确推进 | **否** | OTG 状态机多次 entry、VBUS decision `old=0 new=1`、`extcon data result usb=1 ret=0`，EXTCON_USB 采样翻转为 1 |
| C. **EXTCON 更新了，但 DWC3 没有响应** | **是，本次的故障点** | 14:37:08 EXTCON_USB=1 且 UDC 仍 `not attached`；直到 14:37:10 supervisor 发起 re-probe，14:37:14 才出现 RESET/CONNECT。二者之间无自发 DWC3 connect 事件 |
| D. DWC3 响应了，但枚举没有完成 | **否** | re-probe 后 55 条 EP0 SETUP、UDC `configured / high-speed`、IRQ31 大幅增长 |
| E. USB 已枚举，问题发生在 DHCP 或更后面 | **否** | dnsmasq `DHCPREQUEST/DHCPACK`、Windows RNDIS `origin=Dhcp`、SSH 恢复（均为补充取证）；未出现 APIPA |

**注意**：C 层结论只能说明「extcon 上升沿后 DWC3 没有自发重连动作」，**不能**据此断言具体内核函数或寄存器路径——诊断日志没有采集 `dwc3_gadget_pullup()` / `soft_connect` / `pullups_connected` 的打点。同样，本次恢复包含 supervisor re-probe，**不能**用这一次结果证明「内核自己也能恢复」。

## 7. 测试后清理检查（第四节）

| 检查项 | 结果 |
|---|---|
| 诊断日志完整生成 | 是，73,893 字节 / 329 行，`--- capture start ---` 第 42 行、`--- capture end ---` 第 326 行 |
| 日志头部完整 | 是，第 1 行标题；含版本、开始时间、release、uname、时长、`kernel_stream`、UDC/extcon/IRQ 初始快照、5 条 selector 清单、`enabled_rule_ok=5/5`、`enabled_rule_count=18` |
| 五条 dynamic_debug 规则全部关闭 | 是，`RG353PS_enabled=0`、`conflict_enabled=0` |
| debugfs 恢复运行前状态 | 是，运行前未挂载、运行后未挂载（脚本自挂自卸） |
| 残留后台进程 | 0 |
| UDC 正常 | 是，`configured / high-speed / high-speed`；extcon `USB=1` |
| 日志截断 / 采集失败 | 无截断标记，329 行远低于 20000 行上限；`[kmsg]` 170 行、`[sample]` 112 行；EP2/bulk-out 高频行 0 条；无 `rule_enable_failed=`，5 条规则全部启用成功 |
| 设备配置改动 | 无。未改内核、Supervisor、DHCP、MTP、RNDIS 或任何系统设置；采集脚本留在 `/tmp`，日志留在 `/mnt/SDCARD` |

日志提交前已扫描密码、令牌、私钥、MAC、IP、主机名等敏感字段：**诊断日志内均无命中**（只含设备型号、内核版本、寄存器/IRQ/链路状态）。报告中引用的 dnsmasq 记录已省略主机 MAC 与 Windows 主机名。

## 8. 未知 / 未覆盖项（不得推断为确定故障）

- extcon 上升沿后 DWC3 无自发响应的**具体内核路径未知**：本次未采集 pullup / soft_connect / `pullups_connected` 打点，无法把现象定位到某个函数。
- **若禁用 supervisor re-probe，设备是否会自行恢复，未知**：本轮禁止修改恢复策略，未做该对照实验。
- 插入瞬间 BVALID 三次抖动（`bvalid=1/0/1`）以及插入时又出现一次 `DWC3 DISCONNECT event` 的成因未知（接触抖动、主机复位或 PHY 内部 bounce 均有可能）。
- 14:37:10–14:37:11 采样中 `irq31=N/A` 是读取瞬时失败还是接口短暂消失，未知。
- 内核 printk 时间轴与 `/proc/uptime` 基准分叉，墙钟换算基于相邻采样点近似，误差 ≤ 0.5 秒。
- 诊断脚本不采集 supervisor / dnsmasq / Windows 侧事件，这三部分结论来自采集后的只读取证，时间精度低于日志内部对齐。
- 单次成功样本不能代表统计特性；此前 40 次矩阵测试的 19/40 re-probe 比例仍然有效。

## 9. 下一步最值得调查的具体环节

**B 层：`EXTCON_USB` 上升沿 → DWC3 gadget 重连动作缺失。** 优先在 `drivers/usb/dwc3/gadget.c` 的 `dwc3_gadget_disconnect_interrupt()` / `dwc3_gadget_pullup()` 上补少量 `dev_dbg` 打点（`pullups_connected`、`pm_runtime_get_sync()` 返回、`connected`、`soft_connect` 调用），与现有 `extcon data result` 打点在同一条动态调试时间线上对齐；再用同一拔插流程复测，确认「extcon=1 之后是否根本没有任何 pullup(1) 到达 `dwc3_gadget_soft_connect()`」。

理由：本次日志已把故障范围收敛到 extcon 与 DWC3 之间，且 supervisor 的 re-probe 是唯一让它恢复的动作；继续在 PHY / IRQ 侧加码或做整卡压力测试不会带来新信息。按本轮约束，**先提交证据与分析，不改驱动、不改恢复策略**。
