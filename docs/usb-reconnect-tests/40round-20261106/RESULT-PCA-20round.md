# PC-A USB OTG 重连复测结果（2026-11-06，两次 20 轮 run）

## 环境

- 内核 `7.2.7-baseos-rg353ps` / `BASEOS_BUILD=aa3536b-dirty-20261106013813`（9 个 DWC3 RECONNECT 注入点）
- 脚本 `usb-reconnect-diag.sh` v1.1（`c254496d…d4ae1cc`）
- 主机 PC-A；每组 10 轮 线1 + 10 轮 线3，中间 1 次换线（不计轮）
- 节奏：拔线 → ~3s → 插回 → ≤20s 观察，每 30s 一轮

### 两次运行

| run | 时间(UTC) | 诊断日志 | 上限 | 结果 |
|---|---|---|---|---|
| run1 | 04:50–05:00 | `usb-reconnect-diag-ABORTED-cap-044730.log` | 20000（**被 WARN 风暴截断**） | 19/20 OK，1 次 DHCP 失败 |
| run2 | 05:11–05:21 | `usb-reconnect-diag-PCA-run2.log`（4503 行，**未截断**） | 500000 | **20/20 OK，内核细节完整** |

> run2 为本轮**权威数据集**（`cycles.csv` 1–20 行即 run2）；run1 作为**复现/对照**保存在案。

## A. 总体（run2，20 轮）

| 指标 | 数值 |
|---|---|
| 测试轮数 | 20 |
| 20s 内恢复 | **20 / 20** |
| Supervisor re-probe | **8 / 20（40%）** |
| 无 re-probe | 12（4 轮插入即 configured/addressed + 8 轮 not-attached 自恢复） |
| Path A（PULLUP→SOFTCONNECT→UDC） | 8 |
| Path B | 12 |
| RNDIS / DHCP / MTP | 20 / 20 / 20 |
| 恢复耗时 | 1–11s（中位 4s） |

## B. 分线（run2）

| 组 | re-probe | Path A | 失败 |
|---|---|---|---|
| PC-A + 线1（1–10） | **8 / 10（80%）** | 1,2,3,5,6,7,9,10 | 0 |
| PC-A + 线3（11–20） | **0 / 10（0%）** | 无 | 0 |

## C. 两次合并（PC-A 共 40 轮）

| 组 | re-probe | 比例 |
|---|---|---|
| 线1（run1 7/10 + run2 8/10） | **15 / 20** | **75%** |
| 线3（run1 2/10 + run2 0/10） | **2 / 20** | **10%** |
| 合计 | **17 / 40** | **42.5%** |

**核心结论：re-probe 高度依赖线材，且两次独立运行一致复现**——线1 75% vs 线3 10%。整体 42.5% 与旧基线 47.5% 接近，但"整体比例"掩盖了强烈的线材分化。

> ⚠️ 混淆因素：线1 全部在前 10 轮、线3 全部在后 10 轮，线材与顺序**未分离**。建议 PC-B 侧**反序**（先线3 后线1）或随机化，以区分"线材"与"顺序/热身"。

## D. 逐轮（run2）

| 轮 | 线 | 拔出 | 恢复 | 耗时 | UDC(插入) | 路径 | re-probe | BVALID | OTG |
|---|---|---|---|---:|---|---|---|---:|---:|
| 1 | 线1 | 05:11:01 | 05:11:10 | 9s | not attached | A | 是 | 4 | 4 |
| 2 | 线1 | 05:11:31 | 05:11:42 | 11s | not attached | A | 是 | 4 | 4 |
| 3 | 线1 | 05:12:00 | 05:12:11 | 11s | not attached | A | 是 | 6 | 6 |
| 4 | 线1 | 05:12:32 | 05:12:34 | 2s | configured | B | 否 | 4 | 3 |
| 5 | 线1 | 05:13:02 | 05:13:11 | 9s | not attached | A | 是 | 4 | 4 |
| 6 | 线1 | 05:13:31 | 05:13:42 | 11s | not attached | A | 是 | 6 | 5 |
| 7 | 线1 | 05:14:00 | 05:14:11 | 11s | not attached | A | 是 | 4 | 4 |
| 8 | 线1 | 05:14:32 | 05:14:33 | 1s | addressed | B | 否 | 2 | 2 |
| 9 | 线1 | 05:15:01 | 05:15:10 | 9s | not attached | A | 是 | 4 | 4 |
| 10 | 线1 | 05:15:30 | 05:15:41 | 11s | not attached | A | 是 | 4 | 4 |
| — | 换线 | 05:16:00 | 05:16:06 | 6s | not attached | 过渡 | — | — | — |
| 11 | 线3 | 05:16:32 | 05:16:36 | 4s | not attached | B-self | 否 | 2 | 2 |
| 12 | 线3 | 05:17:01 | 05:17:05 | 4s | not attached | B-self | 否 | 2 | 2 |
| 13 | 线3 | 05:17:30 | 05:17:34 | 4s | not attached | B-self | 否 | 2 | 2 |
| 14 | 线3 | 05:18:00 | 05:18:04 | 4s | not attached | B-self | 否 | 2 | 2 |
| 15 | 线3 | 05:18:31 | 05:18:35 | 4s | not attached | B-self | 否 | 2 | 2 |
| 16 | 线3 | 05:19:00 | 05:19:04 | 4s | configured | B | 否 | 2 | **14** |
| 17 | 线3 | 05:19:30 | 05:19:34 | 4s | not attached | B-self | 否 | 2 | 2 |
| 18 | 线3 | 05:20:02 | 05:20:03 | 1s | configured | B | 否 | 2 | 2 |
| 19 | 线3 | 05:20:31 | 05:20:35 | 4s | not attached | B-self | 否 | 2 | 2 |
| 20 | 线3 | 05:21:00 | 05:21:04 | 4s | not attached | B-self | 否 | 2 | 2 |

## E. 关键发现

### E1. 线材依赖强且可复现（最重要）
- run2：线1 8/10 re-probe、线3 0/10；run1：线1 7/10、线3 2/10。
- 合并 40 轮：**线1 75%（15/20） vs 线3 10%（2/20）**。
- 线1（曾被评为"好数据线"）在当前诊断内核下明显更易触发深断开→re-probe；线3（手机线）几乎总能自恢复。
- **未分离顺序因素**（线1 恒在前 10 轮），需 PC-B 反序/随机化验证。

### E2. Path A 的内核序列（8 轮完整命中）
Path A 轮每轮都有完整 `PULLUP entry(×2) → PULLUP soft(×2) → SOFTCONNECT enter/reset/done → UDC connect out → device RESET → EP0 SETUP 枚举(≈71 条)`，与 Supervisor `re-probe done state=configured` 一一对应。Path B 轮只有 `device RESET / EP0 SETUP`，无 PULLUP/SOFTCONNECT/UDC out。

### E3. 仍为 8/9 注入点
20 轮中 `PULLUP short`（`gadget.c:2917, reason=same_state`）**命中 0 次**；其余 8 个调用点均触发。属"规则启用 9/9 ≠ 9 个点都执行"，与前次结论一致。

### E4. WARN 风暴是偶发（run1 出现、run2 未复现）
- run1 第 7 轮：`gadget.c:2076` WARN_ON 在 `dwc3_ep0_interrupt → dwc3_gadget_ep_queue` 爆发 ~2500 次/5s，**同一时刻该轮 DHCP 失败（APIPA 169.254.62.87）**。
- run2：全程 `gadget.c:2076` WARN **0 次**，20 轮全 OK。
- 结论：该 WARN 风暴是**偶发**的深断开/枚举异常，与 DHCP 失败强相关，但并非每轮必现。仍建议列为下一阶段排查点。

### E5. OTG 单轮尖峰
run2 第 16 轮 OTG 决策 14 次（其余 2–6 次），但 UDC 插入即 configured、1–4s 恢复，无失败——OTG 抖动未造成故障。

## F. 限制

- 线材与顺序混淆（见 E1）。
- run2 完整；run1 的 round 8–20 内核细节因 WARN 风暴截断缺失（已由 Supervisor+主机数据覆盖主要指标）。
- MTP 用 PnP `status=OK` 判定；断开瞬间 status 变 Unknown，实例仍在。
- 设备（Supervisor）与主机（监控）时钟差约 15–18s，CSV 以主机时间为准。

## G. 待 PC-B 完成

- PC-B 20 轮建议 `DIAG_MAX_LOG_LINES=500000`（run2 证明足够），并**反序（线3 先、线1 后）**以分离线材/顺序。
- 合并后出最终 40 轮 `RESULT.md`：总体、四组、故障分层、与旧版 19/40 对比、结论。
