# 40 轮 USB OTG 重连复测数据（2026-11-06）

本目录是 RG353PS USB OTG 重连故障**第二阶段 40 轮矩阵复测**的分析报告与数据。

## 文件

| 文件 | 说明 |
|---|---|
| `RESULT-40round.md` | **最终合并分析报告**（39 有效轮，总体/四组/故障分层/与旧基线对比/结论/下一步） |
| `cycles.csv` | 逐轮数据表（40 行，19 列；第 30 轮 `INVALID`＝PC-B 主机断电作废，故有效 39 轮） |
| `RESULT-PCA-20round.md` | PC-A 两次 20 轮（run1/run2）单独分析 |
| `HANDOVER-PC-B.md` | PC-B 测试交接（含"反序以分离线材/顺序"与上限设置） |
| `SHA256SUMS` | 本目录文件校验和 |
| `raw/` | PC-A 原始采集日志 |
| `raw/pcb-run/` | PC-B 原始采集日志（8 个文件） |

## raw/（PC-A）

- `pc-a-run1-usb-reconnect-diag.log`：PC-A 首次 20 轮诊断日志（上限 20000，第 7 轮 WARN 风暴后被截断）
- `pc-a-run1-baseos-usb-debug.log`：对应 Supervisor 日志
- `pc-a-run1-host-monitor.log`：对应主机侧 RNDIS/DHCP/MTP 逐秒监控
- `pc-a-run2-usb-reconnect-diag.log`：PC-A 重跑 20 轮诊断日志（上限 500000，完整未截断，**权威集**）
- `pc-a-run2-baseos-usb-debug.log`：对应 Supervisor 日志
- `pc-a-run2-host-monitor.log`：对应主机侧监控
- `system-snapshot-pc-a.txt`：PC-A 结束时系统快照
- `host-monitor.ps1`：主机侧监控脚本

## raw/pcb-run/（PC-B，8 个文件）

- `usb-reconnect-diag-PCB-L3.log` / `usb-reconnect-diag-PCB-L1.log`：线3、线1 诊断日志（均未截断、无 WARN）
- `baseos-usb-debug-PCB-L3.log` / `baseos-usb-debug-PCB-L1.log`：对应 Supervisor 日志
- `usb-monitor-PCB-L3.log` / `usb-monitor-PCB-L1.log`：主机侧 RNDIS/DHCP/MTP 监控
- `system-snapshot-PCB-L3.txt` / `system-snapshot-PCB-L1.txt`：系统快照

> **重要：PC-B 的 Supervisor 日志是同一份 `/run/baseos-usb-debug.log` 在不同时刻的快照。**
> - `PCB-L3` 快照含线3 十轮（round 21–30）+ 05:51 断电事件，止于 05:55。
> - `PCB-L1` 快照还包含线3 段与 06:01 的一次**测试前试插**，再加线1 十轮（round 31–40）。
> - 因此 **`grep -c "launching asynchronous recovery"` 在 L1 上会得到 3**（试插 1 + 正式 round 34、37 各 1），**不等于 10 轮的 2 次**。以 `cycles.csv` 中按 `round` 记录的 10 轮为准（线1 = 2/10）。

## 关键结论（详见 RESULT-40round.md）

- 39 有效轮：20s 内恢复 39/39，RNDIS/DHCP/MTP 39/39/39，零失败、零 APIPA、零 WARN。
- Supervisor re-probe：**10/39（25.6%）**，旧基线 47.5%。
- 四组：PCA+线1 **8/10**、PCA+线3 0/10、PCB+线1 **2/10**、PCB+线3 0/9。
- 结论：re-probe 是**"线材 × 主机"交互**（线1 在 PC-A 80%、在 PC-B 20%；线3 两机恒 0）；顺序/热身假设已被 PC-B 反序排除。
