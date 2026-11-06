# USB OTG 重连复测 — 40 轮合并最终结果

**数据源**：`cycles.csv` 第 1–40 行（PC-A run2 为 20 行权威集，PC-B 为 20 行，其中 1 行作废）。
**有效样本 39 轮**；PC-A run1 作为历史对照单列，不混入主统计。

| 项 | 值 |
|---|---|
| 内核 | `7.2.7-baseos-rg353ps` / `BASEOS_BUILD=aa3536b-dirty-20261106013813` |
| 注入点 | 9 个 DWC3 RECONNECT（规则 27 条，`enabled_rule_ok=9/9`） |
| 脚本 | `usb-reconnect-diag.sh` v1.1（`c254496d…d4ae1cc`） |
| 采集上限 | 500000 行（两组均未截断） |
| 节奏 | 拔线 → ~3s → 插回，每 30s 一轮 |
| 主机 | PC-A、PC-B（LENOVO 82MS / Win10 19045），均 USB 直连 |
| 顺序 | PC-A：线1 先、线3 后；PC-B：**线3 先、线1 后**（反序） |

## 1. 总体（39 有效轮）

| 指标 | 数值 |
|---|---|
| 20s 内恢复 | **39 / 39（100%）** |
| Supervisor re-probe | **10 / 39（25.6%）** |
| Path A / Path B | 10 / 29 |
| 主机侧 RNDIS / DHCP / MTP | 39 / 39 / 39 |
| DHCP 失败（APIPA） | 1 次（PC-A run1，不在 39 轮内）；39 轮内 **0 次** |
| `gadget.c:2076` WARN | PC-A run1 爆发 1 次；其余 **0 次** |
| 恢复耗时 | Path B 1–5s（中位 4s）；Path A 9–11s |

## 2. 四组分项

| 组 | 有效轮 | re-probe | 比例 | Path A | 失败 |
|---|---:|---:|---:|---:|---:|
| PC-A + 线1 | 10 | 8 | **80%** | 8 | 0 |
| PC-A + 线3 | 10 | 0 | **0%** | 0 | 0 |
| PC-B + 线1 | 10 | 2 | **20%** | 2 | 0 |
| PC-B + 线3 | 9 | 0 | **0%** | 0 | 0 |
| **合计** | **39** | **10** | **25.6%** | 10 | 0 |

## 3. 与历史对照

| 数据集 | 轮数 | re-probe | 说明 |
|---|---:|---:|---|
| 旧基线 | 40 | 19（47.5%） | 本轮改动前 |
| PC-A run1 | 20 | 9（45%） | 上限 20000，round 8–20 内核细节丢失 |
| PC-A run2 | 20 | 8（40%） | 权威集，内核完整 |
| **PC-B（本轮）** | **19** | **2（10.5%）** | 反序，内核完整，零失败 |

线1 在 PC-A 两次运行合计 **15/20（75%）**，线3 合计 **2/20（10%）**。

## 4. 故障分层

| 层 | 观测 | 判定 |
|---|---|---|
| PHY-BVALID-IRQ | 每轮 irq20 稳定 +2；re-probe 轮 +4~+6（重枚举带来额外 BVALID） | 正常，无丢失 |
| OTG | 每轮 2–6 次 VBUS 决策；PC-A 有 1 次尖峰（14 次，未致故障） | 抖动存在但不致故障 |
| EXTCON | 全程 `USB=1 SDP=1`，拔出瞬间 `USB=0` 后恢复 | 正常 |
| DWC3 | 拔插即 `device RESET` + EP0 枚举；re-probe 轮多出 PULLUP/SOFTCONNECT 链 | 正常 |
| UDC | 插入瞬间 `configured` / `addressed` / `not attached` 三态；`not attached` 才是 re-probe 前兆 | 强相关 |
| RNDIS-DHCP | 39/39 成功，IP 恒 192.168.42.106 | 无故障 |
| MTP | 39/39 OK，断开瞬间短暂 Unknown | 无故障 |
| `gadget.c:2076` WARN | 仅 PC-A run1 出现 1 次（伴 APIPA） | 偶发，未在 PC-B 复现 |

**判定规则**：插入瞬间 UDC = `not attached` → 需要 Supervisor 深断开恢复（Path A，9–11s）；`configured`/`addressed` → 自恢复（Path B，1–5s）。39 轮无例外。

## 5. 结论

**1）线材不是唯一变量，而是"线材 × 主机"的交互。**
线3 在 PC-A、PC-B 上分别是 0/10、0/9，跨主机恒定；线1 在 PC-A 是 8/10，在 PC-B 只有 2/10（Fisher p≈0.023）。同一根线1 换主机后深断开概率从 80% 掉到 20%——单用"好线/坏线"解释不了。

**2）顺序/热身假设被排除。**
PC-B 反序后，先测的线3 仍是 0/9，后测的线1 反而 2/10。若"越测越热、越测越糟"成立，先测组应更高，实际先测组最干净。混淆因素已排除，第 1 条结论成立。

**3）re-probe 显著下降。**
25.6%（10/39）vs 旧基线 47.5%（19/40），相对下降约 46%。下降主要来自 PC-B 主机侧（2/19）与线3 的稳定表现，而非内核改动。

**4）故障面收窄到"线1 × PC-A 端口"这一组合。**
39 轮零失败、零 APIPA、零 WARN。可复现的异常只剩：特定线材在特定主机端口上更易在拔出时把 DWC3 打成 `not attached`，进而触发 9–11s 的 Supervisor 深断开恢复。

**5）`gadget.c:2076` WARN 是偶发深断开伴生现象。**
PC-A run1 唯一一次爆发同时伴随 DHCP 失败（APIPA），PC-A run2 与 PC-B 共 39 轮为 0。不是每轮必现，优先级低于 UDC 进入 `not attached` 的根因。

## 6. 下一步建议（按性价比排序）

1. **主机端口侧排查**：同一根线1 换 PC-A 的不同端口（前置/后置、USB2/USB3、直连 vs HUB）复测 10 轮，隔离"端口供电/VBUS 放电时序"与"控制器型号"。这是 D2 的直接验证手段。
2. **抓拔出瞬间的 VBUS 波形**：`not attached` 只在拔出时产生，怀疑 VBUS 掉电过快导致 dwc3 未走 `PULLUP` 软断开路径。示波器/USB 分析仪可直接证伪或证实。
3. **`gadget.c:2076` WARN 分支加固**：`dwc3_ep0_interrupt → dwc3_gadget_ep_queue` 的 `WARN_ON` 建议改为降级处理 + 计数，避免再出现 2500 次/5s 的风暴。
4. **若继续扩样本**：线1 × PC-A 端口矩阵（3 口 × 10 轮）比再加主线轮数更有信息量；线3 已无需再测。

## 7. 文件清单

- `RESULT-40round.md`（本文件）、`cycles.csv`（40 行）、`RESULT-PCA-20round.md`、`HANDOVER-PC-B.md`、`README.md`
- `raw/`：PC-A 原始日志（run1/run2 诊断、Supervisor、主机监控、系统快照）
- `raw/pcb-run/`：PC-B 原始日志 8 个（线1/线3 诊断、Supervisor、主机监控、系统快照）

校验：`SHA256SUMS`。

> 注意：PC-B 的 Supervisor 日志是 `/run/baseos-usb-debug.log` 的不同时刻快照——L1 快照同时含线3 段与 06:01 的一次测试前试插，故 `grep -c "launching asynchronous recovery"` 在 L1 上为 3（试插 1 + 正式 round 34、37），**不等于 10 轮的 2 次**。re-probe 计数以 `cycles.csv` 的按轮记录为准（PCB 线1 = 2/10）。
