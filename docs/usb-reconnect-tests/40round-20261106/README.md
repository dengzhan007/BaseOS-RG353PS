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
| `raw/` | PC-A 原始采集日志（见下） |

## raw/ 说明

- `pc-a-run1-usb-reconnect-diag.log`：PC-A 首次 20 轮诊断日志（上限 20000，第 7 轮 WARN 风暴后被截断）
- `pc-a-run1-baseos-usb-debug.log`：对应 Supervisor 日志
- `pc-a-run1-host-monitor.log`：对应主机侧 RNDIS/DHCP/MTP 逐秒监控
- `pc-a-run2-usb-reconnect-diag.log`：PC-A 重跑 20 轮诊断日志（上限 500000，完整未截断，**权威集**）
- `pc-a-run2-baseos-usb-debug.log`：对应 Supervisor 日志
- `pc-a-run2-host-monitor.log`：对应主机侧监控
- `system-snapshot-pc-a.txt`：PC-A 结束时系统快照（release/uname/UDC/extcon/interrupts）
- `host-monitor.ps1`：主机侧监控脚本

## 未包含

- **PC-B 原始日志未随本目录上传**（RESULT 中所称 `pcb-run/` 8 个文件保存在 PC-B 本机；本次仅上传 PC-B 的逐轮汇总数据，已并入 `cycles.csv` 第 21–40 行）。
- PC-B 诊断/主机监控原始日志如需归档，可后续从 PC-B 补传至 `raw/pc-b-*`。

## 关键结论（详见 RESULT-40round.md）

- 39 有效轮：20s 内恢复 39/39，RNDIS/DHCP/MTP 39/39/39，零失败、零 APIPA、零 WARN。
- Supervisor re-probe：**10/39（25.6%）**，旧基线 47.5%。
- 四组：PCA+线1 **8/10**、PCA+线3 0/10、PCB+线1 **2/10**、PCB+线3 0/9。
- 结论：re-probe 是**"线材 × 主机"交互**（线1 在 PC-A 80%、在 PC-B 20%；线3 两机恒 0）；顺序/热身假设已被 PC-B 反序排除。
